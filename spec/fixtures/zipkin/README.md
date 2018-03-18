Zipkin Schema
=============

Generated from the Swagger 2.0 specification `zipkin2-api.yaml`:

  https://github.com/openzipkin/zipkin-api

Using `openapi2jsonschema`:

  https://github.com/garethr/openapi2jsonschema

    openapi2jsonschema --stand-alone \
      https://raw.githubusercontent.com/openzipkin/zipkin-api/master/zipkin2-api.yaml

The `--stand-alone` flag causes the generated schemas to embed any schems they
reference. However, a couple tweaks have to be made to the resulting
`listofspans.json` schema to make it usable by Ruby's `json-schma` libarary:

  - The top level `type` has to be changed from `object` to `array`. This seems
    like a bug in the convesion tool.

  - The top level `$schema` reference to `http://json-schema.org/schema#` has
    to be removed. This is probably fine, we can assume what was generated is
    valid.
