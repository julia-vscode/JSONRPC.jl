@static if isdefined(JSON, :JSONStyle)
    const JSONSerialization = JSON.JSONStyle
    const DefaultJSONSerialization = JSON.JSONWriteStyle

    _serialize_json(serialization::JSONSerialization, value) = JSON.json(value; style=serialization)
else
    const JSONSerialization = JSON.Serialization
    const DefaultJSONSerialization = JSON.StandardSerialization

    _serialize_json(serialization::JSONSerialization, value) = sprint(JSON.show_json, serialization, value)
end

_parse_json(value) = JSON.parse(value; dicttype=Dict{String,Any})
