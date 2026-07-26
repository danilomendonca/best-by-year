require 'json'
require 'uri'
require 'cgi'
require 'net/http'

# The manifest is built per-request (see Manifest#manifest) so the year list
# stays current — a constant would freeze Time.now.year at process boot.

OPTIONAL_META = [:posterShape, :background, :logo, :videos, :description, :releaseInfo, :imdbRating, :director, :cast, :dvdRelease, :released, :inTheaters, :certification, :runtime, :language, :country, :awards, :website, :isPeered]

CINEMETA_YEAR_URL = 'https://cinemeta-catalogs.strem.io/year/catalog/%s/year/genre=%s&skip=%s.json'

# In-memory, thread-safe cache for the fully-fetched, IMDB-rating-sorted catalog
# of a single (type, year). Cinemeta can't do "year filter + rating sort" in one
# query, so we must fetch-every-page-then-sort; caching means we pay that cost
# once per (type, year) instead of on every request. See ROADMAP.md.
class YearCatalogCache
  # Past years are effectively immutable, so cache them for ~a month. The
  # current year keeps gaining titles, so refresh it a few times a day. An
  # empty result almost always means a transient Cinemeta failure, so keep it
  # only briefly so it self-heals instead of freezing a bad answer for weeks.
  CURRENT_YEAR_TTL = 6 * 60 * 60        # 6 hours
  PAST_YEAR_TTL    = 30 * 24 * 60 * 60  # 30 days
  EMPTY_TTL        = 60                  # 1 minute

  Entry = Struct.new(:value, :expires_at)

  def initialize
    @store = {}
    @mutex = Mutex.new
  end

  # Return the cached value for +key+, or compute it via the block and store it.
  # The block must return [value, ttl_seconds]. Computation runs outside the
  # lock so a slow Cinemeta fetch doesn't serialize every other request; the
  # cost is that concurrent misses for the same key may each fetch once.
  def fetch(key)
    now = Time.now
    @mutex.synchronize do
      entry = @store[key]
      return entry.value if entry && entry.expires_at > now
    end

    value, ttl = yield

    @mutex.synchronize do
      @store[key] = Entry.new(value, Time.now + ttl)
    end
    value
  end
end

CATALOG_CACHE = YearCatalogCache.new

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

    [200, @@headers, [ manifest.to_json ]]
  end

  private

  # Oldest year offered in the dropdown. Older years are the *smallest*
  # Cinemeta catalogs (1985 ≈ 232 movies vs 2024 ≈ 712) so they fetch faster,
  # and with per-year caching the length of this list is essentially free.
  EARLIEST_YEAR = 1980

  def manifest
    # window from EARLIEST_YEAR through the current year, current year first
    current_year = Time.now.year
    year_options = (EARLIEST_YEAR..current_year).to_a.map(&:to_s).reverse

    {
      id: "danil0vsky.bestbyyear",
      version: "2.2.0",

      name: "Danil0vsky Best By Year",
      description: "A simple and much needed movies/series filter by year and rating",

      types: [ :movie, :series ],

      catalogs: [
        {
            type: :movie,
            id: "Best By Year",
            extra: [
                name: "genre",
                options: year_options,
                isRequired: true
            ]
        },
        {
            type: :series,
            id: "Hello, Ruby",
            extra: [
                name: "genre",
                options: year_options,
                isRequired: true
            ]
        }
      ],

      resources: [
        "catalog"
      ]
    }
  end
end

class Catalog < Resource
  # How many items we return per catalog response. Stremio pages by advancing
  # +skip+ by the size of the page it received, so it walks the cached list in
  # PAGE_SIZE-sized steps until it gets a short (or empty) page.
  PAGE_SIZE = 100

  def initialize(app, cache: CATALOG_CACHE)
    super(app)
    @cache = cache
  end

  def call(env)
    args = parse_request(env)
    # extract year and skip from extraArgs, e.g.: genre=2024&skip=44
    firstArgs = args[:extraArgs].first
    year = firstArgs&.match(/genre=(\d+)/)&.captures&.first || Time.now.year.to_s
    skip = (firstArgs&.match(/skip=(\d+)/)&.captures&.first || 0).to_i

    page = best_by_year(args[:type], year).slice(skip, PAGE_SIZE) || []
    catalog = {metas: page}

    [200, @@headers, [catalog.to_json]]
  end

  # The full, rating-sorted list for (type, year), served from cache when warm.
  def best_by_year(type, year=Time.now.year.to_s)
    @cache.fetch([type, year]) do
      list = fetch_sorted(type, year)
      [list, ttl_for(year, list)]
    end
  end

  private

  def ttl_for(year, list)
    return YearCatalogCache::EMPTY_TTL if list.empty?

    if year == Time.now.year.to_s
      YearCatalogCache::CURRENT_YEAR_TTL
    else
      YearCatalogCache::PAST_YEAR_TTL
    end
  end

  # Fetch every Cinemeta page for the year and sort by IMDB rating, best first.
  def fetch_sorted(type, year)
    # iterate over the catalog until we get all the items, 50 at a time, until we get an empty list
    fulllist = []
    skip = 0
    loop do
      uri = URI(CINEMETA_YEAR_URL % [type, year, skip])
      res = Net::HTTP.get_response(uri)
      if res.is_a?(Net::HTTPSuccess)
          list = JSON.parse(res.body)["metas"]
      else
          list = [] # failed to load catalog from Cinemeta
      end
      break if list.nil? || list.empty?

      fulllist += list
      skip += 50
    end

    fulllist.sort_by { |m| m["imdbRating"].to_f }.reverse
  end
end
