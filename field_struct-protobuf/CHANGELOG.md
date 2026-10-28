# Changelog

## [Unreleased]

### Added

- `FieldStruct::Protobuf.proto`, `.file_descriptor`, `.message_class`, `.to_message`, `.from_message`, `.encode` and `.decode`: Protocol Buffers for FieldStruct classes, built at runtime with no protoc step (see the README's mapping table). Every field declares its number with `proto: {number: n}`; numbers are never inferred.
- RBS signatures in `sig/`, generated from the YARD comments and packaged with the gem. google-protobuf ships none, so its messages are typed `Object` / `Class`.
