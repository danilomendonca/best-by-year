require 'json'
require 'uri'
require 'cgi'
require 'net/http'

CURRENT_YEAR_PLUS_ONE = Time.now.year + 1

MANIFEST = {
  id: "danil0vsky.bestbyyear",
  version: "2.0.0",

  name: "Danil0vsky Best By Year",
  description: "A simple and much needed movies/series filter by year and rating",

  types: [ :movie, :series ],

  catalogs: [
    {
        type: :movie,
        id: "Best By Year",
        extra: [
            name: "genre",
            options: (2000..CURRENT_YEAR_PLUS_ONE).to_a.map(&:to_s).reverse,
            isRequired: true
        ]
    },
    {
        type: :series,
        id: "Hello, Ruby",
        extra: [
            name: "genre",
            options: (2000..CURRENT_YEAR_PLUS_ONE).to_a.map(&:to_s).reverse,
            isRequired: true
        ]
    }
  ],

  resources: [
    "catalog"
  ]
}

OPTIONAL_META = [:posterShape, :background, :logo, :videos, :description, :releaseInfo, :imdbRating, :director, :cast, :dvdRelease, :released, :inTheaters, :certification, :runtime, :language, :country, :awards, :website, :isPeered]

CINEMETA_YEAR_URL = 'https://cinemeta-catalogs.strem.io/year/catalog/%s/year/genre=%s&skip=%s.json'

class NotFound
  def call(env)
    [404, {"Content-Type" => "text/plain"}, ["404 Not Found"]]
  end
end

# Base class with some common behaviour
class Resource
  @@headers = {
    "Access-Control-Allow-Origin" => "*",
    "Access-Control-Allow-Headers" => "*",
    "Content-Type" => "application/json"
  }

  def initialize(app)
    @app = app
  end

  def parse_request(env)
    segments = env["PATH_INFO"][1..-1] # Remove the leading slash
      .sub(/\.\w+$/, '') # Remove extension if any
      .split("/")
      .map { |seg| CGI.unescape(seg) }

    { type: segments[0], id: segments[1], extraArgs: segments[2..-1] }
  end
end

class Manifest < Resource
  def call(env)
    return @app.call(env) unless env["PATH_INFO"].empty?

    [200, @@headers, [ MANIFEST.to_json ]]
  end
end

class Catalog < Resource
  def call(env)
    args = parse_request(env)
    # extract year and skip from extraArgs, e.g.: genre=2024&skip=44
    firstArgs = args[:extraArgs].first
    year = firstArgs&.match(/genre=(\d+)/)&.captures&.first || Time.now.year.to_s
    skip = firstArgs&.match(/skip=(\d+)/)&.captures&.first || 0
    catalog = {metas: best_by_year(args[:type], year)}

    [200, @@headers, [catalog.to_json]]
  end

  def best_by_year(type, year=Time.now.year.to_s)
    # iterate over the catalog until we get all the items, 44 at a time, until we get an empty list
    fulllist = []
    skip = 0
    loop do
      uri = URI(CINEMETA_YEAR_URL % [type, year, skip])
      res = Net::HTTP.get_response(uri)
      if res.is_a?(Net::HTTPSuccess)
          list = JSON.parse(res.body)["metas"]
      else
          JSON.parse("[]") # failed to load catalog from Cinemeta
      end
      break if list.empty?

      fulllist += list
      skip += 50
    end

    fulllist.sort_by { |m| m["imdbRating"].to_i || '0.0'  }.reverse
  end
end
