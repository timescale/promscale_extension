-- Our tracing implementation is based on OTLP spec, though OTLP spec
-- doesn't mandate span name to be non empty[1], we have a constraint
-- in the _ps_trace.operation table which raises error on empty span name.
-- On the other hand, Jaeger span name can be empty and their storage
-- integration tests validates the same[2]. Jaeger author even suggested to
-- remove[3] the constraint as it shouldn't trouble any part of the system.
-- [1] https://github.com/open-telemetry/opentelemetry-proto/blob/724e427879e3d2bae2edc0218fff06e37b9eb46e/opentelemetry/proto/trace/v1/trace.proto#L110-L121
-- [2] https://github.com/jaegertracing/jaeger/blob/7872d1b07439c3f2d316065b1fd53e885b26a66f/plugin/storage/integration/fixtures/traces/default.json#L6
-- [3] https://github.com/jaegertracing/jaeger/pull/3922#issuecomment-1256505785
ALTER TABLE _ps_trace.operation DROP CONSTRAINT operation_span_name_check;
