"""`scan_event` finds what `field` and `path` find, in one pass.

    pixi run test
"""

from std.testing import TestSuite, assert_equal

from jscan import Range, field, path, scan_event


def _same(line: String) raises:
    var b = line.as_bytes()
    var r = Range(0, len(b))
    var f = scan_event(b, r)
    var want: List[Range] = [
        field(b, r, "id"), field(b, r, "type"), field(b, r, "created_at"),
        path(b, r, "repo", "name"), path(b, r, "actor", "login"),
        field(b, r, "payload"),
    ]
    var got: List[Range] = [
        f.id, f.type, f.created_at, f.repo_name, f.actor_login, f.payload
    ]
    for k in range(len(want)):
        assert_equal(got[k].start, want[k].start, String(line, " field ", k))
        assert_equal(got[k].end, want[k].end, String(line, " field ", k))


def test_agrees_with_field() raises:
    var long = String("x") * 70
    var lines: List[String] = [
        '{"id":"1","type":"PushEvent","actor":{"id":2,"login":"me"},"repo":{"name":"o/r"},"payload":{"a":[1,{"b":"}"}],"s":"\\"{"},"public":true,"created_at":"2025-01-01T00:00:00Z"}',
        String('{"id":"2","payload":{"msg":"', long, '\\\\', long, '\\"]}', long, '"},"created_at":"2025-01-01T00:00:00Z","type":"X"}'),
        '{"type":"A","type":"B","id":"3","id":"4","repo":{"name":"a"},"repo":{"name":"b"}}',
        '{ "id" : 5 , "actor" : null , "repo" : "notanobject" , "payload" : [ ] }',
        '{"id":"6","broken" "created_at":"2025-01-01T00:00:00Z"}',
        '{"id":"7","payload":{"deep":[[[[{"k":"v"}]]]],"created_at":"inside"}}',
        String('{"', long, '":1,"ids":2,"id":"8","created_atx":1,"payloads":{}}'),
        '[1,2,3]',
        '',
        '{"id":"9","payload":{"unterminated":"',
    ]
    for line in lines:
        _same(line)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
