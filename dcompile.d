import reggae.dependencies;
import std.exception;
import std.process;
import std.stdio;
import std.conv;
import std.regex;
import std.algorithm;
import std.array;


int main(string[] args) {
    try {

        enforce(args.length > 4, "Usage: dcompile <compiler> <options> <objFile> <srcFile> <depFile>");
        immutable depFile = args[$ - 1];
        immutable srcFile = args[$ - 2];
        immutable objFile = args[$ - 3];
        const compArgs = args[1 .. $ - 3] ~ ["-v", "-of" ~ objFile, "-c", srcFile];
        const compRes = execute(compArgs);
        enforce(compRes.status == 0, text("Could not compile with args:\n", compArgs.join(" "), " :\n",
                                          compRes.output.split("\n").
                                          filter!isInterestingCompilerErrorLine.join("\n")));

        auto file = File(depFile, "w");
        file.write(objFile, ": ");

        foreach(immutable dep; dMainDependencies(compRes.output)) {
            file.write(dep, " ");
        }

        file.writeln;

    } catch(Exception ex) {
        stderr.writeln(ex.msg);
        return 1;
    }

    return 0;
}


bool isInterestingCompilerErrorLine(in string line) @safe pure nothrow {
    if(line.startsWith("binary ")) return false;
    if(line.startsWith("version ")) return false;
    if(line.startsWith("config ")) return false;
    if(line.startsWith("parse ")) return false;
    if(line.startsWith("importall ")) return false;
    if(line.startsWith("import ")) return false;
    if(line.startsWith("semantic")) return false;
    if(line.startsWith("code ")) return false;
    if(line.startsWith("function ")) return false;
    return true;
}
