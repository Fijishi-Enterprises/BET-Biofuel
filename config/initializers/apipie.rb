Apipie.configure do |config|
  config.app_name                = "BETYdb"
  config.default_version         = "v0"
  config.api_base_url            = ""
  config.doc_base_url            = "/apipie"
  # where is your API defined?
  config.api_controllers_matcher = "#{Rails.root}/app/controllers/api/v0/*.rb"


end