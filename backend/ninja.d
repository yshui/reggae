module reggae.backend.ninja;


import reggae.build;
import reggae.range;
import reggae.rules;
import reggae.config;
import std.array;
import std.range;
import std.algorithm;
import std.exception: enforce;
import std.conv;
import std.string: strip;
import std.path: defaultExtension, absolutePath;

string ruleToNinjaString(Rule rule) @safe pure nothrow {
    final switch(rule) with(Rule) {
        case compileD: return "_dcompile";
        case compileCpp: return "_cppcompile";
        case compileC: return "_ccompile";
        case link: return "_link";
        case shell: assert(0, "ruleToNinjaString doesn't work for shell");
    }
}

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
    return [NinjaEntry("rule _dcompile",
                       ["command = .reggae/dcompile --objFile=$out --depFile=$DEPFILE " ~
                        dCompiler ~ " $flags $includes $stringImports $in",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
            NinjaEntry("rule _link",
                       ["command = " ~ dCompiler ~ " $flags -of$out $in"]),
            NinjaEntry("rule _cppcompile",
                       ["command = " ~ cppCompiler ~ " $flags $includes -MMD -MT $out -MF $DEPFILE -o $out -c $in",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
            NinjaEntry("rule _ccompile",
                       ["command = " ~ cCompiler ~ " $flags $includes -MMD -MT $out -MF $DEPFILE -o $out -c $in",
                        "deps = gcc",
                        "depfile = $DEPFILE"]),
        ];
}


struct Ninja {
    NinjaEntry[] buildEntries;
    NinjaEntry[] ruleEntries;

    this(Build build, in string projectPath = "") @safe {
        _build = build;
        _projectPath = projectPath;

        foreach(topTarget; _build.targets) {
            foreach(target; DepthFirst(topTarget)) {
                target.command.isDefaultCommand ? defaultRule(target) : customRule(target);
            }
        }
    }

    const(NinjaEntry)[] allBuildEntries() @safe pure nothrow const {
        immutable files = [buildFilePath, reggaePath].join(" ");
        return buildEntries ~
            NinjaEntry("build build.ninja: _rerun | " ~ files,
                       ["pool = console"]);
    }

    const(NinjaEntry)[] allRuleEntries() @safe pure const {
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
    int _counter = 1;

    //@trusted because of join
    void defaultRule(in Target target) @trusted {
        immutable rule = target.command.getRule;

        string[] paramLines;

        if(rule != Rule.link) { //i.e. one of the compile rules
            auto params = ["includes", "flags"];
            if(rule == Rule.compileD) params ~= "stringImports";

            foreach(immutable param; params) {
                import std.stdio;
                debug writeln("param is ", param);
                immutable value = target.command.getParams(_projectPath, param, []).join(" ");
                debug writeln("value is ", value);
                paramLines ~= param ~ " = " ~ value;
            }

            paramLines ~= "DEPFILE = " ~ target.outputs[0] ~ ".dep";
        } else {
            auto params = ["flags"];

            foreach(immutable param; params) {
                immutable value = target.command.getParams(_projectPath, param, []).join(" ");
                paramLines ~= param ~ " = " ~ value;
            }

        }

        buildEntries ~= NinjaEntry("build " ~ target.outputs[0] ~ ": " ~ ruleToNinjaString(rule) ~ " " ~
                                   target.dependencyFilesString(_projectPath),
                                   paramLines);
    }

    void customRule(in Target target) @safe {
        //rawCmdString is used because ninja needs to find where $in and $out are,
        //so shellCommand wouldn't work
        immutable shellCommand = target.rawCmdString(_projectPath);
        immutable implicitInput =  () @trusted { return !shellCommand.canFind("$in");  }();
        immutable implicitOutput = () @trusted { return !shellCommand.canFind("$out"); }();

        if(implicitOutput) {
            implicitOutputRule(target, shellCommand);
        } else if(implicitInput) {
            implicitInputRule(target, shellCommand);
        } else {
            explicitInOutRule(target, shellCommand);
        }
    }

    void explicitInOutRule(in Target target, in string shellCommand, in string implicitInput = "") @safe {
        import std.regex;
        auto reg = regex(`^[^ ]+ +(.*?)(\$in|\$out)(.*?)(\$in|\$out)(.*?)$`);

        auto mat = shellCommand.match(reg);
        enforce(!mat.captures.empty, text("Could not find both $in and $out.\nCommand: ",
                                          shellCommand, "\nCaptures: ", mat.captures));
        immutable before  = mat.captures[1].strip;
        immutable first   = mat.captures[2];
        immutable between = mat.captures[3].strip;
        immutable last    = mat.captures[4];
        immutable after   = mat.captures[5].strip;

        immutable ruleCmdLine = getRuleCommandLine(target, shellCommand, before, first, between, last, after);
        bool haveToAdd;
        immutable ruleName = getRuleName(targetCommand(target), ruleCmdLine, haveToAdd);

        immutable deps = implicitInput.empty
            ? target.dependencyFilesString(_projectPath)
            : implicitInput;

        auto buildLine = "build " ~ target.outputs.join(" ") ~ ": " ~ ruleName ~
            " " ~ deps;
        if(!target.implicits.empty) buildLine ~= " | " ~  target.implicitFilesString(_projectPath);

        string[] buildParamLines;
        if(!before.empty)  buildParamLines ~= "before = "  ~ before;
        if(!between.empty) buildParamLines ~= "between = " ~ between;
        if(!after.empty)   buildParamLines ~= "after = "   ~ after;

        buildEntries ~= NinjaEntry(buildLine, buildParamLines);

        if(haveToAdd) {
            ruleEntries ~= NinjaEntry("rule " ~ ruleName, [ruleCmdLine]);
        }
    }

    void implicitOutputRule(in Target target, in string shellCommand) @safe nothrow {
        bool haveToAdd;
        immutable ruleCmdLine = getRuleCommandLine(target, shellCommand, "" /*before*/, "$in");
        immutable ruleName = getRuleName(targetCommand(target), ruleCmdLine, haveToAdd);

        immutable buildLine = "build " ~ target.outputs.join(" ") ~ ": " ~ ruleName ~
            " " ~ target.dependencyFilesString(_projectPath);
        buildEntries ~= NinjaEntry(buildLine);

        if(haveToAdd) {
            ruleEntries ~= NinjaEntry("rule " ~ ruleName, [ruleCmdLine]);
        }
    }

    void implicitInputRule(in Target target, in string shellCommand) @safe {
        string input;

        immutable cmdLine = () @trusted {
            string line = shellCommand;
            auto allDeps = (target.dependencyFilesString(_projectPath) ~ " " ~
                            target.implicitFilesString(_projectPath)).splitter(" ");
            foreach(string dep; allDeps) {
                if(line.canFind(dep)) {
                    line = line.replace(dep, "$in");
                    input = dep;
                }
            }
            return line;
        }();

        explicitInOutRule(target, cmdLine, input);
    }

    //@trusted because of canFind
    string getRuleCommandLine(in Target target, in string shellCommand,
                              in string before = "", in string first = "",
                              in string between = "",
                              in string last = "", in string after = "") @trusted pure nothrow const {

        auto cmdLine = "command = " ~ targetRawCommand(target);
        if(!before.empty) cmdLine ~= " $before";
        cmdLine ~= shellCommand.canFind(" " ~ first) ? " " ~ first : first;
        if(!between.empty) cmdLine ~= " $between";
        cmdLine ~= shellCommand.canFind(" " ~ last) ? " " ~ last : last;
        if(!after.empty) cmdLine ~= " $after";
        return cmdLine;
    }

    //Ninja operates on rules, not commands. Since this is supposed to work with
    //generic build systems, the same command can appear with different parameter
    //ordering. The first time we create a rule with the same name as the command.
    //The subsequent times, if any, we append a number to the command to create
    //a new rule
    string getRuleName(in string cmd, in string ruleCmdLine, out bool haveToAdd) @safe nothrow {
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
        if(!rulesWithSameCmd.empty)
            return () @trusted { return rulesWithSameCmd.front.mainLine.replace("rule ", ""); }();

        //if we got here then it's the first time we see "cmd" with a new
        //ruleCmdLine, so we add it
        haveToAdd = true;
        import std.conv: to;
        return cmd ~ "_" ~ (++_counter).to!string;
    }

    string output(const(NinjaEntry)[] entries) @safe pure const nothrow {
        return entries.map!(a => a.toString).join("\n\n");
    }
}

//@trusted because of splitter
private string targetCommand(in Target target) @trusted pure nothrow {
    return targetRawCommand(target).sanitizeCmd;
}

//@trusted because of splitter
private string targetRawCommand(in Target target) @trusted pure nothrow {
    return target.expandCommand.splitter(" ").front;
}

//ninja doesn't like symbols in rule names
//@trusted because of replace
private string sanitizeCmd(in string cmd) @trusted pure nothrow {
    import std.path;
    //only handles c++ compilers so far...
    return cmd.baseName.replace("+", "p");
}
