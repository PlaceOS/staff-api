# class Surveys::Pages < Application
#   base "/api/staff/v1/surveys/pages"

#   # =====================
#   # Filters
#   # =====================

#   @[AC::Route::Filter(:before_action, except: [:index, :create])]
#   private def find_page(id : Int64)
#     @page = Survey::Page.find!(id)
#   end

#   getter! page : Survey::Page

#   # =====================
#   # Routes
#   # =====================

#   # returns a list of pages
#   @[AC::Route::GET("/")]
#   def index(
#     @[AC::Param::Info(description: "the survey id to get pages for", example: "1234")]
#     survey_id : Int64? = nil
#   ) : Array(Survey::Page::Responder)
#     query = Survey::Page.query.select("id, title, description, question_order")

#     if survey_id
#       survey = Survey.find!(survey_id)
#       if (page_order = survey.page_order) && !page_order.empty?
#         query = query.where { id.in?(page_order) }
#       else
#         return [] of Survey::Page::Responder
#       end
#     end

#     query.to_a.map(&.as_json)
#   end

#   # creates a new page
#   @[AC::Route::POST("/", body: :page_body, status_code: HTTP::Status::CREATED)]
#   def create(page_body : Survey::Page::Responder) : Survey::Page::Responder
#     page = page_body.to_page
#     raise Error::ModelValidation.new(page.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating page data") if !page.save
#     page.as_json
#   end

#   # patches an existing page
#   @[AC::Route::PUT("/:id", body: :page_body)]
#   @[AC::Route::PATCH("/:id", body: :page_body)]
#   def update(page_body : Survey::Page::Responder) : Survey::Page::Responder
#     changes = page_body.to_page(update: true)

#     {% for key in [:title, :description, :question_order] %}
#         begin
#             page.{{key.id}} = changes.{{key.id}} if changes.{{key.id}}_column.defined?
#         rescue NilAssertionError
#         end
#         {% end %}

#     raise Error::ModelValidation.new(page.errors.map { |error| {field: error.column, reason: error.reason} }, "error validating page data") if !page.save
#     page.as_json
#   end

#   # show a page
#   @[AC::Route::GET("/:id")]
#   def show(
#     @[AC::Param::Info(name: "id", description: "the page id", example: "1234")]
#     page_id : Int64
#   ) : Survey::Page::Responder
#     page.as_json
#   end

#   # deletes the page
#   @[AC::Route::DELETE("/:id", status_code: HTTP::Status::ACCEPTED)]
#   def destroy : Nil
#     page.delete
#   end
# end
