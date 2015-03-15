module reggae.ninja;


import reggae.build;
import reggae.range;
import reggae.rules;
import std.array;
import std.range;
import std.algorithm;
import std.exception: enforce;
import std.conv: text;
import std.string: strip;
import std.path: defaultExtension;

struct NinjaEntry {
    string mainLine;
    string[] paramLines;
    string toString() @safe pure nothrow const {
        return (mainLine ~ paramLines.map!(a => "  " ~ a).array).join("\n");
    }
}


/**
 * Pre-built rules
 */
NinjaEntry[] defaultRules() @safe pure nothrow {
    immutable dcompiler = "dmd";
    immutable cppcompiler = "g++";
    immutable ccompiler = "gcc";
    return [NinjaEntry("rule _dcompile",
                       ["command = .reggae/dcompile " ~ dcompiler ~
                        " $flags $includes $stringImports $out $in $DEPFILE",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
            NinjaEntry("rule _dlink",
                       ["command = " ~ dcompiler ~ " $flags -of$out $in"]),
            NinjaEntry("rule _cppcompile",
                       ["command = " ~ cppcompiler ~ " $flags $includes -MMD -MT $out -MF $DEPFILE -o $out -c $in",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
            NinjaEntry("rule _ccompile",
                       ["command = " ~ ccompiler ~ " $flags $includes -MMD -MT $out -MF $DEPFILE -o $out -c $in",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
        ];
}


struct Ninja {
    NinjaEntry[] buildEntries;
    NinjaEntry[] ruleEntries;

    this(Build build, in string projectPath = "") @safe {
        _build = build;
        _projectPath = projectPath.absolutePath;

        foreach(topTarget; _build.targets) {
            foreach(target; DepthFirst(topTarget)) {
                auto rawCmdLine = target.inOutCommand(_projectPath);
                rawCmdLine.isDefaultCommand ? defaultRule(target, rawCmdLine) : customRule(target, rawCmdLine);
            }
        }
    }

    const(NinjaEntry)[] allBuildEntries() @safe pure nothrow const {
        import reggae.config;
        immutable files = [buildFilePath, reggaePath].join(" ");
        return buildEntries ~
            NinjaEntry("build build.ninja: _rerun | " ~ files,
                       ["pool = console"]);
    }

    const(NinjaEntry)[] allRuleEntries() @safe pure const {
        import reggae.config;
        immutable _dflags = dflags == "" ? "" : " --dflags='" ~ dflags ~ "'";

        return ruleEntries ~ defaultRules ~
            NinjaEntry("rule _rerun",
                       ["command = " ~ reggaePath ~ " -b ninja" ~ _dflags ~ " " ~ projectPath,
                        "generator = 1"]);
    }

    string buildOutput() @safe pure nothrow const {
        return output(allBuildEntries);
    }

    string rulesOutput() @safe pure const {
        return output(allRuleEntries);
    }

private:
    Build _build;
    string _projectPath;

    //@trusted because of join
    void defaultRule(in Target target, in string rawCmdLine) @trusted {
        immutable rule = rawCmdLine.getDefaultRule;

        string[] paramLines;

        if(rule != "_dlink") { //i.e. one of the compile rules
            auto params = ["includes", "flags"];
            if(rule == "_dcompile") params ~= "stringImports";

            foreach(immutable param; params) {
                immutable value = rawCmdLine.getDefaultRuleParams(param, []).join(" ");
                paramLines ~= param ~ " = " ~ value;
            }

            paramLines ~= "DEPFILE = " ~ target.outputs[0] ~ ".d";
        } else {
            auto params = ["flags"];

            foreach(immutable param; params) {
                immutable value = rawCmdLine.getDefaultRuleParams(param, []).join(" ");
                paramLines ~= param ~ " = " ~ value;
            }

        }

        buildEntries ~= NinjaEntry("build " ~ target.outputs[0] ~ ": " ~ rule ~ " " ~
                                   target.dependencyFiles(_projectPath),
                                   paramLines);
    }

    void customRule(in Target target, in string rawCmdLine) @safe {
        import std.regex;
        auto reg = regex(`^[^ ]+ +(.*?)(\$in|\$out)(.*?)(\$in|\$out)(.*?)$`);

        auto mat = rawCmdLine.match(reg);
        enforce(!mat.captures.empty, text("Could not find both $in and $out.\nCommand: ",
                                          rawCmdLine, "\nCaptures: ", mat.captures));
        immutable before = mat.captures[1].strip;
        immutable first = mat.captures[2];
        immutable between = mat.captures[3].strip;
        immutable last  = mat.captures[4];
        immutable after = mat.captures[5].strip;

        immutable ruleCmdLine = getRuleCommandLine(target, before, first, between, last, after);
        bool haveToAdd;
        immutable ruleName = getRuleName(targetCommand(target), ruleCmdLine, haveToAdd);
        auto buildLine = "build " ~ target.outputs[0] ~ ": " ~ ruleName ~
            " " ~ target.dependencyFiles(_projectPath);
        if(!target.implicits.empty) buildLine ~= " | " ~ target.implicitFiles(_projectPath);
        string[] buildParamLines;
        if(!before.empty)  buildParamLines ~= "before = "  ~ before;
        if(!between.empty) buildParamLines ~= "between = " ~ between;
        if(!after.empty)   buildParamLines ~= "after = "   ~ after;

        buildEntries ~= NinjaEntry(buildLine, buildParamLines);

        if(haveToAdd) {
            ruleEntries ~= NinjaEntry("rule " ~ ruleName, [ruleCmdLine]);
        }
    }

    //@trusted because of canFind
    string getRuleCommandLine(in Target target, in string before, in string first, in string between,
                              in string last, in string after) @trusted pure nothrow const {
        immutable rawCmdLine = target.inOutCommand(_projectPath);
        auto cmdLine = "command = " ~ targetRawCommand(target);
        if(!before.empty) cmdLine ~= " $before";
        cmdLine ~= rawCmdLine.canFind(" " ~ first) ? " " ~ first : first;
        if(!between.empty) cmdLine ~= " $between";
        cmdLine ~= rawCmdLine.canFind(" " ~ last) ? " " ~ last : last;
        if(!after.empty) cmdLine ~= " $after";
        return cmdLine;
    }

    //Ninja operates on rules, not commands. Since this is supposed to work with
    //generic build systems, the same command can appear with different parameter
    //ordering. The first time we create a rule with the same name as the command.
    //The subsequent times, if any, we append a number to the command to create
    //a new rule
    //@trusted because of replace
    string getRuleName(in string cmd, in string ruleCmdLine, out bool haveToAdd) @trusted nothrow {
        immutable ruleMainLine = "rule " ~ cmd;
        //don't have a rule for this cmd yet, return just the cmd
        if(!ruleEntries.canFind!(a => a.mainLine == ruleMainLine)) {
            haveToAdd = true;
            return cmd;
        }

        //so we have a rule for this already. Need to check if the command line
        //is the same

        //same cmd: either matches exactly or is cmd_{number}
        auto isSameCmd = (in NinjaEntry entry) {
            bool sameMainLine = entry.mainLine.startsWith(ruleMainLine) &&
            (entry.mainLine == ruleMainLine || entry.mainLine[ruleMainLine.length] == '_');
            bool sameCmdLine = entry.paramLines == [ruleCmdLine];
            return sameMainLine && sameCmdLine;
        };

        auto rulesWithSameCmd = ruleEntries.filter!isSameCmd;
        assert(rulesWithSameCmd.empty || rulesWithSameCmd.array.length == 1);

        //found a sule with the same cmd and paramLines
        if(!rulesWithSameCmd.empty) return rulesWithSameCmd.front.mainLine.replace("rule ", "");

        //if we got here then it's the first time we see "cmd" with a new
        //ruleCmdLine, so we add it
        haveToAdd = true;
        import std.conv: to;
        static int counter = 1;
        return cmd ~ "_" ~ (++counter).to!string;
    }

    string output(const(NinjaEntry)[] entries) @safe pure const nothrow {
        return entries.map!(a => a.toString).join("\n\n");
    }

}

//@trusted because of splitter
private string targetCommand(in Target target) @trusted pure nothrow {
    return target.command.splitter(" ").front.sanitizeCmd;
}

//@trusted because of splitter
private string targetRawCommand(in Target target) @trusted pure nothrow {
    return target.command.splitter(" ").front;
}

//@trusted because of replace
private string sanitizeCmd(in string cmd) @trusted pure nothrow {
    import std.path;
    //only handles c++ compilers so far...
    return cmd.baseName.replace("+", "p");
}
