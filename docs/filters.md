# Display filters

VDF is parsed without evaluating Ruby. Acquisition uses BPF, compiled independently before the helper starts.

## Operators and expressions

| Operation | Syntax |
| --- | --- |
| Presence | `tcp`, `http.host` |
| Boolean logic | `!tcp`, `tcp && ip`, `tcp || udp`; `not`, `and`, `or` also work |
| Comparisons | `==`, `!=`, `~=`, `<`, `<=`, `>`, `>=`; `eq`, `ne`, `any_ne`, `lt`, `le`, `gt`, `ge` also work |
| Contains | `http.host contains "example"` |
| Regular expression | `http.host matches "^www[.]"` |
| Membership and inclusive ranges | `tcp.port in {80, 443, 8000..8080}` |
| Nonzero bitmask | `tcp.flags & 0x12` |

Negation binds before conjunction, which binds before disjunction. Mixing conjunction and disjunction without parentheses produces a warning. Syntax errors identify the input position. Unknown fields warn and behave as missing fields.

Inputs are bounded to 8192 bytes, 511 tokens, and 64 nested expressions so malformed expressions cannot exhaust a worker stack.

## Values and types

Literals include decimal and hexadecimal integers, floats, booleans, IPv4/IPv6 addresses, CIDR prefixes, MAC addresses, quoted strings, and hexadecimal bytes. Strings support escaped quotes, backslashes, and `\xNN` byte escapes. Regular expressions have a 100 ms timeout.

## Repeated and missing fields

Repeated layers and aliases can supply multiple values: `tcp.port` contains source and destination ports; `ip.addr` contains source and destination addresses. `==` succeeds when any value matches, `!=` when no value matches (including a missing field), and `~=` when any value differs. Other comparisons on missing fields are false. A present boolean field whose value is false passes a presence test.

## Execution and saved filters

Frame metadata, columns, protocol presence, and persisted analysis annotations can be filtered without dissection. Other fields use workers in 10,000-frame batches. Results appear progressively; replacing the expression cancels the preceding scan. Acquisition continues during filtering.

Select a protocol field to apply or prepare its expression from the Filter menu, including AND/OR/negation combinations. Preparing changes the input without applying it. Named filters and recent expressions persist.
