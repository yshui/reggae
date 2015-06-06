module reggae.backend.binary;


import reggae.build;
import reggae.range;
import reggae.config;
import std.algorithm: all, splitter, cartesianProduct, any;
import std.range: chain;
import std.file: timeLastModified, thisExePath, exists;
import std.process: execute, executeShell;
import std.path: absolutePath;
import std.typecons: tuple;
import std.exception: enforce;
import std.stdio;
import std.parallelism: parallel;
import std.conv: text;

@safe:

struct Binary {
    Build build;
    string projectPath;

    this(Build build, string projectPath) pure {
        this.build = build;
        this.projectPath = projectPath;
    }

    void run() const @system { //@system due to parallel

        bool didAnything;

        checkReRun(); //1st check if we must rebuild ourselves

        //ugh, arrow anti-pattern
        foreach(topTarget; build.targets) {
            foreach(level; ByDepthLevel(topTarget)) {
                foreach(target; level.parallel) {
                    foreach(dep; chain(target.dependencies, target.implicits)) {
                        if(cartesianProduct(dep.outputsInProjectPath(projectPath),
                                            target.outputsInProjectPath(projectPath)).
                           any!(a => a[0].newerThan(a[1]))) {

                            didAnything = true;
                            mkDir(target);
                            immutable cmd = target.shellCommand(projectPath);
                            writeln("[build] " ~ cmd);
                            immutable res = executeShell(cmd);
                            enforce(res.status == 0, "Could not execute " ~ cmd ~ ":\n" ~ res.output);
                        }
                    }
                }
            }
        }

        if(!didAnything) writeln("Nothing to do");
    }

private:

    void checkReRun() const {
        immutable myPath = thisExePath;
        if(reggaePath.newerThan(myPath) || buildFilePath.newerThan(myPath)) {
            immutable reggaeRes = execute(reggaeCmd);
            enforce(reggaeRes.status == 0,
                    text("Could not run ", reggaeCmd.join(" "), " to regenerate build:\n",
                         reggaeRes.output));

            immutable buildRes = execute([myPath]);
            enforce(buildRes.status == 0, "Could not redo the build:\n", buildRes.output);
        }
    }

    string[] reggaeCmd() pure nothrow const {
        immutable _dflags = dflags == "" ? "" : " --dflags='" ~ dflags ~ "'";
        auto mutCmd = [reggaePath, "-b", "binary"];
        if(_dflags != "") mutCmd ~= _dflags;
        return mutCmd ~ projectPath;
    }
}


bool newerThan(in string a, in string b) nothrow {
    try {
        return a.timeLastModified > b.timeLastModified;
    } catch(Exception) { //file not there, so newer
        return true;
    }
}

//@trusted because of mkdirRecurse
private void mkDir(in Target target) @trusted {
    foreach(output; target.outputs) {
        import std.file: exists, mkdirRecurse;
        import std.path: dirName;
        if(!output.dirName.exists) mkdirRecurse(output.dirName);
    }
}
