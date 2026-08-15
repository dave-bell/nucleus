# Sample (fixture for test/mix/tasks/nucleus_trace_test.exs)

### FIX-A01 — Fixture action one, claimed by the fixture test

Actor: Fixture
Given a fixture
When the task scans this file
Then FIX-A01 is defined

### FIX-A02 — Fixture action two, never claimed

Actor: Fixture
Given a fixture
When the task scans this file
Then FIX-A02 is defined, but no test claims it
