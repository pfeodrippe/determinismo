# Antithesis-format projects

Systems as an Antithesis project has them: a Compose file, and test commands in an image under
`/opt/antithesis/test/v1/<template>/`, written in shell (`bank`), Python (`python`) and Java
(`java`). They are not how determinismo tests are written (see the test programs in
`examples/`): they check that the Compose importer runs such a project unchanged, its test
commands and Antithesis-format assertions included. `zig build e2e` explores them.
