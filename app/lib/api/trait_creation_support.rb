module Api::TraitCreationSupport

  include JsonHandler, CsvHandler

  private

  # Exception to signal document didn't validate against schema or had other
  # structural problems not captured by the schema constraints.
  class InvalidDocument < StandardError
  end

  # Exception used for various data errors that prevent data from being saved,
  # including lookup of metadata references, out-of-range values, missing
  # attributes, etc.
  class InvalidData < StandardError
  end

  class InvalidDateSpecification < StandardError
    def initialize(node, message, tag_message = message)
      node.set_attribute("error", tag_message)
      super(message)
    end
  end

  class NotFoundException < StandardError
    def initialize(node, entity_name, selection_criteria,
                   message = "No #{entity_name} could be found matching " +
                             "#{selection_criteria}")
      node.set_attribute("error", "match not found")
      super(message)
    end
  end

  class NotUniqueException < StandardError
    def initialize(node, entity_name, selection_criteria)
      node.set_attribute("error", "multiple matches")
      super("Multiple #{entity_name} objects were found matching #{selection_criteria}")
    end
  end

  # Given data, an XML string, extract the information from it and insert
  # appropriate rows into the entities, traits, and covariates tables.
  def create_traits_from_post_data(data)

    begin

      doc = Nokogiri::XML(data, nil, nil, Nokogiri::XML::ParseOptions::STRICT)

      schema_validate(doc)

      trait_data_set_node = doc.root

      ActiveRecord::Base.transaction do

        # The root element "trait-data-set" can be treated just like a
        # "trait-group" node.
        process_trait_group_node(trait_data_set_node, {})

        if @lookup_errors.size > 0 ||
            @model_validation_errors.size > 0 ||
            @database_insertion_errors.size > 0 ||
            @date_data_errors.size > 0

          raise InvalidData  # roll back everything if there was any error

        end

      end # transaction

    rescue InvalidData

      @result = Hash.from_xml(doc.to_s)

      raise

    rescue StandardError => e

      e.backtrace.each do |line|
        if !line.match /\.rvm/
          logger.debug line
        end
      end
      logger.debug e.message

      raise e

    else

      @result = Hash.from_xml(doc.to_s)

    ensure

      if @lookup_errors.size > 0 ||
          @model_validation_errors.size > 0 ||
          @database_insertion_errors.size > 0 ||
          @date_data_errors.size > 0

        @new_trait_ids = []
      end

    end

    return

  end # method

  def process_trait_group_node(trait_group_node, defaults)

    defaults = defaults.clone

    if trait_group_node.xpath("boolean(entity)")
      entity_node = trait_group_node.xpath("entity").first
      entity = get_or_create_entity(entity_node)
      defaults[:entity_id] = entity.id
    end

    if trait_group_node.xpath("boolean(defaults)")
      defaults = merge_new_defaults(trait_group_node.xpath("defaults").first, defaults)
    end

    trait_group_node.xpath("trait").each do |trait_node|
      process_trait_node(trait_node, defaults)
    end

    trait_group_node.xpath("trait-group").each do |trait_group_node|
      process_trait_group_node(trait_group_node, defaults)
    end

  end


  def process_trait_node(trait_node, defaults)

    defaults = defaults.clone

    if !defaults.has_key?(:entity_id)
      # If this trait node has a specified entity, use it:
      if trait_node.xpath("boolean(entity)")
        entity_node = trait_node.xpath("entity").first
        entity = get_or_create_entity(entity_node)
        defaults[:entity_id] = entity.id
      end
      # Otherwise, do nothing; don't make an anonymous singleton entity for this
      # trait.
    end

    column_values = merge_new_defaults(trait_node, defaults)

    # add stat info
    column_values.merge!(get_stat_info(trait_node))

    column_values[:mean] = trait_node.attribute("mean").value

    column_values[:notes] = (trait_node.xpath("notes").first && trait_node.xpath("notes").first.content) || ""

    # Set dateloc and timeloc to 9 ("no data") if no date was given:
    if !column_values.has_key? :date
      column_values[:dateloc] = 9
      column_values[:timeloc] = 9
    end

    # Every trait has the same user_id value:
    column_values[:user_id] = current_user.id

    begin

      new_trait = Trait.create!(column_values)

      @new_trait_ids << new_trait.id

      if trait_node.xpath("boolean(covariates)")

        trait_node.xpath("covariates/covariate").each do |covariate_node|

          column_values = get_foreign_keys(covariate_node) # get variable_id

          if @lookup_errors.size == 0

            # Only create a covariate if there were no lookup errors:

            column_values[:level] = covariate_node.attribute("level").value
            
            column_values[:trait_id] = new_trait.id

            Covariate.create!(column_values)

          end

        end

      end

    rescue ActiveRecord::RecordInvalid => invalid
      # add error info to trait node
      trait_node.set_attribute("model_validation_errors", invalid.record.errors.messages)
      @model_validation_errors << "#{invalid.record.errors.messages}"
      return
    rescue ActiveRecord::StatementInvalid => e
      # Note: In Rails 4 we can get information from the original_exception attribute
      message = e.message.sub!(/.*ERROR: *([^\n]*).*/m, '\1')
      trait_node.set_attribute("database_exception", message)
      @database_insertion_errors << message
      raise # Don't continue with this transaction -- it's unstable.
    end

  end

  def merge_new_defaults(element_node, defaults)

    defaults = defaults.clone

    defaults.merge!(get_foreign_keys(element_node, defaults))

    set_datetime_defaults(element_node, defaults)

    new_access_level  = get_access_level(element_node)
    if new_access_level
      defaults[:access_level] = new_access_level
    end

    return defaults
  end

  def set_datetime_defaults(element_node, defaults)

    if element_node.has_attribute?("local_datetime")

      if !defaults.has_key?(:site_id)
        raise InvalidDateSpecification.new(element_node,
                                           "You can't have a local_datetime attribute on a trait-group's defaults element if no default site has been specified.",
                                           "bad date specification; see error output")
      elsif Site.find(defaults[:site_id]).time_zone.nil?
        raise InvalidDateSpecification.new(element_node,
                                           "You can't have a local_datetime attribute on a trait-group's defaults element if the default site doesn't specify a time zone.",
                                           "bad date specification; see error output")
      end

      if element_node.name == 'defaults' &&
          !element_node.xpath("../*[local-name(.) != 'defaults']//site").empty?

        raise InvalidDateSpecification.new(element_node,
                                           "You can't have a local_datetime attribute on a trait-group's defaults element if a trait or trait-group descendant sets (or re-sets) the site.",
                                           "bad date specification; see error output")
      end

    end

    if element_node.has_attribute?("utc_datetime")
      if element_node.has_attribute?("local_datetime")
        raise InvalidDateSpecification.new(element_node,
                                           "You can't specify both utc_datetime and local_datetime as attributes of the same element.")
      else
        date_string = element_node.attribute("utc_datetime").value

        if date_string.size == 11
          # date only
          defaults[:timeloc] = 9
          # fill out the time portion with zeroes, but keep the "Z" at the end:
          date_string = date_string[0..-2] + "T00:00:00Z"
        elsif !date_string.match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/) # sanity check; validation should already catch this
          raise InvalidDateSpecification.new(element_node,
                                             "Date string #{date_string} has an unexpected format.")
        else
          # date and time
          defaults[:timeloc] = 1
        end

        utc_datetime = date_string
      end
    elsif element_node.has_attribute?("local_datetime")
      date_string = element_node.attribute("local_datetime").value

      if date_string.size == 10
        # date only
        defaults[:timeloc] = 9
        # fill out the time portion with zeroes
        date_string += "T00:00:00"
      elsif !date_string.match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?$/) # sanity check; validation should already catch this
        raise InvalidDateSpecification.new(element_node,
                                           "Date string #{date_string} has an unexpected format.")
      else
        # date and time
        defaults[:timeloc] = 1
      end

      Time.use_zone site_timezone(defaults) do
        utc_datetime = Time.zone.parse(date_string)
      end
    else
      # no date information on this node; return without setting any defaults
      return
    end

    defaults[:date] = utc_datetime
    defaults[:dateloc] = 5

  rescue InvalidDateSpecification => e
    @date_data_errors << e.message
  end


  # To-Do: Combine this code with similar code elsewhere when branch containing it is merged in.
  def site_timezone(defaults)

    site_id = defaults[:site_id]

    if site_id.nil?
      site_timezone = 'UTC'
    else
      site_timezone = (Site.find(site_id)).time_zone
      if site_timezone.blank?
        site_timezone = 'UTC'
      end
    end

    return site_timezone

  end

  def get_stat_info(element_node)
    stat_info = {}
    if element_node.xpath("boolean(stat)")
      stat_node = element_node.xpath("stat").first
      stat_info[:statname] = stat_node.attribute("name").value
      stat_info[:n] = stat_node.attribute("sample_size").value
      stat_info[:stat] = stat_node.attribute("value").value
    end
    return stat_info
  end

  def get_access_level(element_node)
    element_node.attribute("access_level") && element_node.attribute("access_level").value
  end


  # Given an element node containing child elements corresponding to the
  # foreign-key columns in the traits table, look up the id to use for each
  # foreign key.  If `defaults` contains the key `:treatment_id`, then an
  # `InvalidDocument` exception will be raised if `parent_node` has a `citation`
  # child element.  An `InvalidDocument` exception will also be raised if
  # `defaults` does not contains the key `:citation_id` and if `parent_node`
  # contains a `treatment` element but not a `citation` element.
  #
  # TO DO: Enforce these constraints using RelaxNG, Schematron, or XSLT instead.
  def get_foreign_keys(parent_node, defaults = {})
    id_hash = {}

    treatment_node = nil # we set this in the block below (for later processing) if found

    parent_node.element_children.each do |child_node|

      entity_name = child_node.name
      if !["site", "species", "citation", "treatment", "variable", "method"].include? entity_name
        next
      end

      if entity_name == "treatment"

        # Store this away for later processing outside the loop when we are sure
        # to have captured the citation information:
        treatment_node = child_node

        next
      end

      # Catch cases where we try to set a new citation after defaulting the
      # treatment:
      if entity_name == "citation"
        if !defaults[:treatment_id].nil?
          @structure_validation_errors << ["You can't reset the citation after setting a treatment default."]
          # TO DO: Enforce this constraint using RelaxNG, Schematron, or XSLT instead.
          raise InvalidDocument
        end
      end

      selection_criteria = attr_hash_2_where_hash(child_node.attributes)

      if entity_name != "species"
        model = (entity_name == "method") ? Methods : entity_name.classify.constantize
        foreign_key = (entity_name + "_id").to_sym
      end

      begin
        case child_node.name

        when "species"
          # If there is a cultivar specified, get cultivar_id:
          if child_node.xpath("boolean(cultivar)")
            cultivar_selection_criteria = attr_hash_2_where_hash(child_node.xpath("cultivar").first.attributes)
            matches = Cultivar.where(cultivar_selection_criteria)
            if matches.size == 0
              raise NotFoundException.new(child_node, "cultivar", cultivar_selection_criteria)
            elsif matches.size > 1
              raise NotUniqueException.new(child_node, "cultivar", cultivar_selection_criteria)
            end
            id_hash[:cultivar_id] = matches.first.id
          else
            # Don't keep cultivar_id associated with overriden species:
            id_hash[:cultivar_id] = nil
          end

          matches = Specie.where(selection_criteria)
          if matches.size == 0
            raise NotFoundException.new(child_node, entity_name, selection_criteria)
          elsif matches.size > 1
            raise NotUniqueException.new(child_node, entity_name, selection_criteria)
          end
          id_hash[:specie_id] = matches.first.id
        else
          matches = model.where(selection_criteria)
          if matches.size == 0
            raise NotFoundException.new(child_node, entity_name, selection_criteria)
          elsif matches.size > 1
            raise NotUniqueException.new(child_node, entity_name, selection_criteria)
          end
          id_hash[foreign_key] = matches.first.id
        end # case
      rescue NotFoundException, NotUniqueException => e
        @lookup_errors << e.message
      end

    end # children.each

    # Process treatment_node if set:
    begin
      if !treatment_node.nil?
        if id_hash[:citation_id].nil?
          if defaults[:citation_id].nil?
            @structure_validation_errors << ["You can't specify a treatment without specifying a citation."]
            # TO DO: Enforce this constraint using RelaxNG, Schematron, or XSLT instead.
            raise InvalidDocument
          else
            citation_id = defaults[:citation_id]
          end
        else
          citation_id = id_hash[:citation_id]
        end

        selection_criteria = attr_hash_2_where_hash(treatment_node.attributes)

        matches = Treatment.where(selection_criteria).select { |t| t.citations.map(&:id).include?(citation_id) }

        if matches.size == 0
          raise NotFoundException.new(treatment_node, "treatment", selection_criteria)
        elsif matches.size > 1
          raise NotUniqueException.new(treatment_node, "treatment", selection_criteria)
        end

        id_hash[:treatment_id] = matches.first.id
      end

      # Catch exceptions outside the loop having to do with treatment lookup:
    rescue NotFoundException, NotUniqueException => e
      @lookup_errors << e.message
    end

    return id_hash
  end

  # Validate the XML document "doc" using the TraitData.xsd schema.  Raise an
  # InvalidDocument exception containing the list of errors returned by the
  # parser if the document is not valid.
  def schema_validate(doc)

    xsd = Nokogiri::XML::Schema.from_document(
      Nokogiri::XML(Rails.root.join('app', 'lib', 'api', 'validation', 'TraitData.xsd').open,
                    nil,
                    nil,
                    Nokogiri::XML::ParseOptions::STRICT))

    xsd.validate(doc).each do |error|
      @structure_validation_errors << error.message
    end

    if !@structure_validation_errors.blank?
      raise InvalidDocument, @structure_validation_errors
    end


  end

  # Convert h from a Hash mapping attribute names to attribute nodes
  # to one mapping attribute names to their value.
  def attr_hash_2_where_hash(h)
    Hash[h.map { |k, v| [k, v.value] }]
  end

  # Search the database for an entity whose data matches the attributes of
  # entity_node and return the Rails object for it.  If none are found, create
  # one and return the Rails object for that.  If multiple matches are found,
  # raise a NotUniqueException.
  def get_or_create_entity(entity_node)
    entity_attributes = attr_hash_2_where_hash(entity_node.attributes)
    name_hash = entity_attributes.select { |k, v| k == "name" }
    matches = Entity.where(name_hash)
    if matches.size == 0 || entity_attributes["name"].blank?
      entity = Entity.create!(entity_attributes)
    elsif matches.size > 1
      raise NotUniqueException.new(entity_node, "entity", name_hash)
    else
      entity = matches.first
      if !entity_attributes["notes"].nil? && entity.notes != entity_attributes["notes"]
        # considered this a failed match
        raise NotFoundException.new(entity_node, "entity", nil,
                                    # custom message:
                                    "The existing entity with name " +
                                    "\"#{entity.name}\" has a conflicting " +
                                    "value for notes.")
      end
    end
    return entity
  rescue NotFoundException, NotUniqueException => e
    @lookup_errors << e.message
    raise InvalidData
  end

end
