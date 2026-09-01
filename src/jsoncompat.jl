@static if isdefined(JSON, :JSONStyle)
    const JSONSerialization = JSON.JSONStyle
    const DefaultJSONSerialization = JSON.JSONWriteStyle
else
    const JSONSerialization = JSON.Serialization
    const DefaultJSONSerialization = JSON.StandardSerialization
end

function _serialize_json(serialization::JSONSerialization, value)
    @static if isdefined(JSON, :JSONStyle)
        return JSON.json(value; style=serialization)
    else
        return sprint(JSON.show_json, serialization, value)
    end
end

_parse_json(value) = JSON.parse(value; dicttype=Dict{String,Any})
