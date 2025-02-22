
# Internal config object
struct Config{P}
    width::Int
    height::Int
    center::Vector{Float64}
    zoom::Int
    provider::P
    id::String
end

"""
    Map(; kw...)

A Leaflet map object that will render as HTML/Javascript in any WebIO.jl page,
or by calling `WebIO.render(yourmap)`.

# Keyword arguments

- `provider = Providers.OSM()`: base layer [`Provider`](@ref).
- `layers`: [`Layer`](@ref) or `Vector{Layer}`.
- `center::Vector{Float64} = Float64[0.0, 0.0]`: center coordinate.
- `width::Int = 900`: map width in pixels.
- `height::Int = 500`: map height in pixels.
- `zoom::Int = 11`: default zoom level.
"""
struct Map{L<:Vector{<:Layer},C,S}
    layers::L
    config::C
    scope::S
end
function Map(;
    layers=Layer[],
    center::Vector{Float64}=Float64[0.0, 0.0],
    width::Int=900,
    height::Int=500,
    zoom::Int=11,
    provider=Providers.OSM(),
)
    if layers isa Layer
        layers = [layers]
    end
    id = string(UUIDs.uuid4())
    conf = Config(width, height, center, zoom, provider, id)
    return Map(layers, conf, leaflet_scope(layers, conf))
end

# WebIO rendering interface
@WebIO.register_renderable(Map) do map
    return WebIO.render(map.scope)
end

# return the html head/body and javascript for a leaflet map
function leaflet_scope(layers, cfg::Config)
    # Define online assets
    urls = [
        "https://unpkg.com/leaflet@1.7.1/dist/leaflet.js",
        "https://unpkg.com/leaflet@1.7.1/dist/leaflet.css", 
        "https://cdnjs.cloudflare.com/ajax/libs/underscore.js/1.8.3/underscore.js",
        "https://cdnjs.cloudflare.com/ajax/libs/chroma-js/1.3.3/chroma.min.js",
    ]

    assets = Asset.(urls)

    # Define the div the map goes in.
    mapnode = Node(:div, "";
        id="map$(cfg.id)",
        style=Dict(
            "flex" => 5,
            "position " => "relative",
            "display" => "flex",
        )
    )

    # Define a wrapper div for sizing
    wrapperdiv = Node(:div, mapnode;
        style=Dict(
            "display" =>"flex",
            "flex-direction" => "column-reverse",
            "min-height" => "$(cfg.height)px",
        )
    )

    # The javascript scope
    scope = Scope(; dom=wrapperdiv, imports=assets)
    # leaflet javascript we run as a callback on load
    mapjs = leaflet_javascript(layers, cfg)
    onimport(scope, mapjs)
    return scope
end

# leaflet_javascript
# generate the leaflet javascript
#
# Returns a WebIO.JSString that holds a 
# javascript callback function for use in `WebIO.onimport`
function leaflet_javascript(layers, cfg::Config)
    io = IOBuffer()
    for (i, layer) in enumerate(layers)
        data = layer.data
        isnothing(GeoInterface.trait(data)) &&
            throw(ArgumentError("data is not a GeoInterace compatible Feature or Geometry"))
        write(io, "var data$i = ", GeoJSON.write(data), ";\n")
        if layer.options[:color] != "nothing"
            color = layer.options[:color]
            if isa(color, Symbol)
                @assert haskey(layer.options, :color_map)
                color_map = layer.options[:color_map]
                write(io, """
                // for categorical variables, converts them into 1...n
                if (data$i.features.length > 0) {
                    if (typeof data$i.features[1].properties.$color != 'number') {
                        colortype$i = "categorical";
                        var values$i = _(data$i.features).chain().pluck("properties").
                            pluck("$color").unique().invert().value();
                        var categories$i = _(data$i.features).chain().pluck("properties").
                            pluck("$color").unique().value();
                        var ncategories$i = categories$i.length;
                        data$i.features.forEach(function(feature, i){
                            var colorindex = parseInt(values$i[feature.properties.$color]);
                            data$i.features[i].properties["$color"] = colorindex / (ncategories$i-1);
                        });
                        console.log(_(data$i.features).chain().pluck("properties").pluck("$color").value());
                    }
                    else {
                        var dataproperties$i = _(data$i.features).chain().pluck("properties");
                        var maxvalue$i = dataproperties$i.pluck("$color").max().value();
                        var minvalue$i = dataproperties$i.pluck("$color").min().value();
                        var range$i = maxvalue$i - minvalue$i;
                        if (maxvalue$i > 0 && minvalue$i < 0){
                            colortype$i = "diverging";
                            absvalue$i = Math.max(Math.abs(minvalue$i), Math.abs(maxvalue$i));
                            maxvalue$i = absvalue$i;
                            minvalue$i =  -absvalue$i;
                            range$i = 2*absvalue$i;
                        }
                        else {
                            colortype$i = "sequential";
                        };
                        data$i.features.forEach(function(feature, i){
                            console.log(feature.properties.$color);
                            var colorvalue = feature.properties.$color - minvalue$i;
                            console.log(colorvalue);
                            data$i.features[i].properties["$color"] = colorvalue / range$i;
                        });
                    };
                    console.log("color scheme:", colortype$i);
                    if (colortype$i == "sequential") {
                        var style$i = function(feature){
                            console.log(feature.properties.$color);
                            return $(layeroptions2style(layer.options, i, :sequential))
                        };
                    }
                    else if (colortype$i == "diverging") {
                        var style$i = function(feature){
                            return $(layeroptions2style(layer.options, i, :diverging))
                        };
                    }
                    else if (colortype$i == "categorical") {
                        var style$i = function(feature){
                            return $(layeroptions2style(layer.options, i, :categorical))
                        };
                    };
                    console.log(style$i);
                };
                """)
            else
                write(io, """
                var style$i = function(feature){
                    return $(layeroptions2style(layer.options, i, :nothing))
                };
                """)
            end
        end
        write(io, """
        L.geoJson(data$i, {
            pointToLayer: function (feature, latlng) {
                return L.circleMarker(latlng, style$i)
            },
            style: style$i
        }).addTo(map);\n
        """)
    end

    layerjs = if length(layers) > 0 
        String(take!(io)) * """
        var group = new L.featureGroup([$(join(("data$i" for i in 1:length(layers)), ", "))]);
        map.fitBounds(group.getBounds());\n
        """ 
    else
        ""
    end

    prov = cfg.provider
    url = JSON3.write(prov.url)
    options = JSON3.write(prov.options)

    callback = """
    function(p) {
        var map = L.map('map$(cfg.id)').setView($(cfg.center), $(cfg.zoom));
        L.tileLayer($url,$options).addTo(map);
        $layerjs
    }
    """

    return WebIO.JSString(callback)
end

option2style(attribute::Real) = string(attribute)
option2style(attribute::String) = "\"$attribute\""
option2style(attribute::Symbol) = "feature.properties.$attribute"

function layeroptions2style(options::Dict{Symbol,Any}, i::Int, colortype::Symbol)
    io = IOBuffer()
    write(io, "{\n")
    write(io, "radius: ", option2style(options[:marker_size]), ",\n")
    write(io, "color: ", option2style(options[:color]), ",\n")
    write(io, "weight: ", option2style(options[:border_width]), ",\n")
    write(io, "opacity: ", option2style(options[:opacity]), ",\n")
    write(io, "fillOpacity: ", option2style(options[:fill_opacity]), ",\n")
    color = options[:color]
    if color isa String
        @assert colortype == :nothing
        write(io, "fillColor: ", option2style(color))
    elseif options[:color_map] != "nothing"
        write(io, "fillColor: chroma.scale(", option2style(options[:color_map]), ")(feature.properties.$color).hex()")
    elseif colortype == :sequential
        write(io, "fillColor: chroma.scale(\"YlGnBu\")(feature.properties.$color).hex()")
    elseif colortype == :diverging
        write(io, "fillColor: chroma.scale(\"RdYlBu\")(feature.properties.$color).hex()")
    elseif colortype == :categorical
        write(io, "fillColor: chroma.scale(\"accent\")(feature.properties.$color).hex()")
    end
    write(io, "}")
    return String(take!(io))
end
