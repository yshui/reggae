//Automatically generated by dtest, do not edit by hand
import unit_threaded.runner;
import std.stdio;

int main(string[] args) {
    writeln("\nAutomatically generated file tests/ut.d");
    writeln(`Running unit tests from dirs ["tests"]`);
    return args.runTests!("tests.simple_foo_reggaefile",
                          "tests.simple_bar_reggaefile",
                          "tests.ninja",
                          "tests.default_rules",
                          "tests.dub_json",
                          "tests.cpprules",
                          "tests.realistic_build",
                          "tests.drules",
                          "tests.range",
                          "tests.reflect",
                          "tests.build",
                          "tests.make",
                          "tests.dependencies",
                          "tests.ctaa",
                          "tests.by_package",
                          "tests.dub_call",
                          "tests.binary",
                          "tests.high_rules",
                          "tests.code_command",
                          "tests.tup",
        );
}
