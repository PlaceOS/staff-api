# rest-api's search and pagination helpers, for controllers ported from it (PPT-2644 PostgreSQL
# full-text search). Adds the `q`, `limit` and `offset` params to the including controller's index
# route and sets `X-Total-Count`, `Content-Range` and `Link` response headers.
module Utils::SearchPagination
  macro included
    getter! search_params : Hash(String, String | Array(String))

    @[AC::Route::Filter(:before_action, only: [:index], converters: {fields: ConvertStringArray})]
    def build_search_params(
      @[AC::Param::Info(name: "q", description: "filters results by the given text: a record matches when any word matches its searchable fields as a whole word, and the last word also matches as a prefix (search as you type)")]
      query : String = "*",
      @[AC::Param::Info(description: "the maximum number of results to return", example: "10000")]
      limit : UInt32 = 100_u32,
      @[AC::Param::Info(description: "the starting offset of the result set, used to implement pagination")]
      offset : UInt32 = 0_u32,
      @[AC::Param::Info(description: "deprecated, ignored — pagination follows the `Link` header's offset")]
      ref : String? = nil,
      @[AC::Param::Info(description: "deprecated, ignored — search covers the resource's indexed fields")]
      fields : Array(String) = [] of String,
    )
      search_params = {
        "q"      => query,
        "limit"  => limit.to_s,
        "offset" => offset.to_s,
        "fields" => fields,
      }
      search_params["ref"] = ref.not_nil! if ref.presence
      @search_params = search_params
    end
  end

  # Paginates any PgORM relation, setting `X-Total-Count`, `Content-Range` and `Link` headers
  def paginate_sql(
    query,
    type : String,
    limit : Int32 = 100,
    offset : Int32 = 0,
    route : String = base_route,
  )
    # ORDER BY must not reach the aggregate — Postgres rejects
    # non-aggregated order columns in a COUNT query
    total = query.unscope(:order).count.to_i32
    results = query.offset(offset).limit(limit).to_a

    range_end = offset + results.size
    response.headers["X-Total-Count"] = total.to_s
    response.headers["Content-Range"] = "#{type} #{offset}-#{range_end}/#{total}"

    if range_end < total
      query_params["offset"] = range_end.to_s
      query_params["limit"] = limit.to_s
      response.headers["Link"] = %(<#{route}?#{query_params}>; rel="next")
    end

    results
  end

  # The `q` param of the current request as a safe tsquery string, or nil
  # when no text filter applies (empty / "*" / nothing searchable).
  def search_tsquery : String?
    Utils::TextSearch.tsquery(search_params["q"]?.as?(String))
  end

  def search_limit : Int32
    (search_params["limit"]?.as?(String).try(&.to_i?) || 100).clamp(0, 10_000)
  end

  def search_offset : Int32
    (search_params["offset"]?.as?(String).try(&.to_i?) || 0).clamp(0, 1_000_000)
  end

  # Splices an array into raw SQL as "ARRAY[?, ?, ...]::text[]", one bound placeholder per element
  def sql_array(list : Array) : String
    "ARRAY[#{list.join(", ") { "?" }}]::text[]"
  end

  # Standard paginated index: applies `q` against the model's `search_vector` column, orders
  # deterministically and emits the pagination headers
  def paginate_search(
    query,
    type : String,
    route : String = base_route,
    order : String = "name, id",
  )
    if tsq = search_tsquery
      query = query.where("search_vector @@ to_tsquery('simple', ?)", tsq)
    end
    paginate_sql(query.order(order), type, limit: search_limit, offset: search_offset, route: route)
  end
end
