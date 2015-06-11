class V1::PublicationsController < ApplicationController

  api!
  def index
    if params[:drafts] == 'true'
      publications = drafts_by_registrator(username: @current_user.username)
    elsif params[:is_actor] == 'true'
      person = Person.find_from_identifier(source: 'xkonto', identifier: @current_user.username)
      if person
        if params[:for_review]
          publications = publications_for_review_by_actor(person_id: person.id)
        else
          publications = publications_by_actor(person_id: person.id)
        end
      else
        publications = []
      end
    elsif params[:is_registrator] == 'true'
      publications = publications_by_registrator(username: @current_user.username)
    else
      publications = Publication.where(is_deleted: false)
    end
    @response[:publications] = publications
    render_json(200)
  end

  api!
  def show
    pubid = params[:pubid]
    publication = Publication.find_by_pubid(pubid)
    if publication.present?
      @response[:publication] = publication.as_json
      @response[:publication][:authors] = people_for_publication(publication_db_id: publication.id)
    else
      generate_error(404, "#{I18n.t "publications.errors.not_found"}: #{params[:pubid]}")
    end
    render_json
  end

  api!
  def create
    params[:publication] = {} if !params[:publication]

    # If datasource is given, perform import through adapter class
    if params.has_key?(:datasource)
      datasource = params[:datasource]
      case datasource
      when "none"
        #do nothing
      when "pubmed"
        pubmed = Pubmed.find_by_id(params[:sourceid])
        if pubmed && pubmed.errors.messages.empty?
          params[:publication].merge!(pubmed.as_json)
        else
          generate_error(422, "#{I18n.t "publications.errors.not_found_in_pubmed"}")
          render_json
          return
        end
      when "gupea"
        gupea = Gupea.find_by_id(params[:sourceid])
        if gupea && gupea.errors.messages.empty?
          params[:publication].merge!(gupea.as_json)
        else
          generate_error(422, "#{I18n.t "publications.errors.not_found_in_gupea"}")
          render_json
          return
        end
      when "libris"
        libris = Libris.find_by_id(params[:sourceid])
        if libris && libris.errors.messages.empty?
          params[:publication].merge!(libris.as_json)
        else
          generate_error(422, "#{I18n.t "publications.errors.not_found_in_libris"}")
          render_json
          return
        end
      when "scopus"
        scopus = Scopus.find_by_id(params[:sourceid])
        if scopus && scopus.errors.messages.empty?
          params[:publication].merge!(scopus.as_json)
        else
          generate_error(422, "#{I18n.t "publications.errors.not_found_in_scopus"}")
          render_json
          return
        end
      else
        generate_error(404, "#{I18n.t "publications.errors.no_datasource"}: #{params[:datasource]}")
        render_json
        return
      end
    elsif params[:datasource].nil? && params[:file]
      handle_file_import params[:file]
    end

    params[:publication][:created_by] = @current_user.username
    params[:publication][:updated_by] = @current_user.username

    create_basic_data
    pub = Publication.new(permitted_params(params))
    if pub.save
      @response[:publication] = pub
      render_json(201)
    else
      generate_error(422, "#{I18n.t "publications.errors.create_error"}", pub.errors)
      render_json
    end
  end

  api!
  def fetch_import_data
    datasource = params[:datasource]
    params[:publication] = {}
    case datasource
    when "none"
      #do nothing
    when "pubmed"
      pubmed = Pubmed.find_by_id(params[:sourceid])
      if pubmed && pubmed.errors.messages.empty?
        params[:publication].merge!(pubmed.as_json)
      else
        generate_error(422, "Identifikatorn #{params[:sourceid]} hittades inte i Pubmed.")
        render_json
        return
      end
    when "gupea"
      gupea = Gupea.find_by_id(params[:sourceid])
      if gupea && gupea.errors.messages.empty?
        params[:publication].merge!(gupea.as_json)
      else
        generate_error(422, "Identifikatorn #{params[:sourceid]} hittades inte i Gupea")
        render_json
        return
      end
    when "libris"
      libris = Libris.find_by_id(params[:sourceid])
      if libris && libris.errors.messages.empty?
        params[:publication].merge!(libris.as_json)
      else
        generate_error(422, "Identifikatorn #{params[:sourceid]} hittades inte i Libris")
        render_json
        return
      end
    when "scopus"
      scopus = Scopus.find_by_id(params[:sourceid])
      if scopus && scopus.errors.messages.empty?
        params[:publication].merge!(scopus.as_json)
      else
        generate_error(422, "Identifikatorn #{params[:sourceid]} hittades inte i Scopus")
        render_json
        return
      end
    else
      generate_error(404, "Given datasource is not configured: #{params[:datasource]}")
    end

    @response[:publication] = params[:publication]
    render_json

  end

  api!
  def update
    pubid = params[:pubid]
    publication_old = Publication.where(is_deleted: false).find_by_pubid(pubid)
    if publication_old
      params[:publication] = publication_old.attributes_indifferent.merge(params[:publication])
      params[:publication][:updated_by] = @current_user.username

      Publication.transaction do
        if !params[:publication][:publication_type]
          publication_new = Publication.new(permitted_params(params))
        else
          publication_type = PublicationType.find_by_code(params[:publication][:publication_type])
          if publication_type.present?
            publication_new = Publication.new(publication_type.permitted_params(params, global_params))
          else
            generate_error(422, "#{I18n.t "publications.errors.unknown_publication_type"}: #{params[:publication][:publication_type]}")
            render_json
            raise ActiveRecord::Rollback
          end
        end
        publication_new.new_authors = params[:publication][:authors]
        if publication_old.update_attribute(:is_deleted, true) && publication_new.save
          create_affiliation(publication_new.id, params[:publication][:authors]) unless params[:publication][:authors].blank?
          @response[:publication] = publication_new.as_json
          @response[:publication][:authors] = people_for_publication(publication_db_id: publication_new.id)
          render_json(200)
        else
          generate_error(422, "#{I18n.t "publications.errors.update_error"}", publication_new.errors)
          render_json
          raise ActiveRecord::Rollback
        end
      end
    else
      generate_error(404, "#{I18n.t "publications.errors.not_found"}: #{params[:pubid]}")
      render_json
    end
  end

  api!
  def publish
    pubid = params[:pubid]
    publication_old = Publication.where(is_deleted: false).find_by_pubid(pubid)
    if publication_old
      if publication_old.published_at
        # It is not possible to publish an already published publication
        generate_error(422, "#{I18n.t "publications.errors.already_published"}: #{params[:pubid]}")
        render_json
        return
      end
      params[:publication] = publication_old.attributes_indifferent.merge(params[:publication])
      params[:publication][:updated_by] = @current_user.username

      Publication.transaction do
        if !params[:publication][:publication_type]
          publication_new = Publication.new(permitted_params(params))
        else
          publication_type = PublicationType.find_by_code(params[:publication][:publication_type])
          if publication_type.present?
            publication_new = Publication.new(publication_type.permitted_params(params, global_params))
          else
            generate_error(422, "#{I18n.t "publications.errors.unknown_publication_type"}: #{params[:publication][:publication_type]}")
            render_json
            raise ActiveRecord::Rollback
          end
        end
        if !publication_new.published_at
          publication_new.published_at = DateTime.now
        end
        publication_new.new_authors = params[:publication][:authors]

        if publication_old.update_attribute(:is_deleted, true) && publication_new.save
          create_affiliation(publication_new.id, params[:publication][:authors]) unless params[:publication][:authors].blank?
          @response[:publication] = publication_new.as_json
          @response[:publication][:authors] = people_for_publication(publication_db_id: publication_new.id)
          render_json(200)
        else
          generate_error(422, "#{I18n.t "publications.errors.publish_error"}", publication_new.errors)
          render_json
          raise ActiveRecord::Rollback
        end
      end
    else
      generate_error(404, "#{I18n.t "publications.errors.not_found"}: #{params[:pubid]}")
      render_json
    end
  end


  api!
  def destroy 
    pubid = params[:pubid]
    publication = Publication.where(is_deleted: false).find_by_pubid(pubid)
    if !publication.present?
      generate_error(404, "#{I18n.t "publications.errors.not_found"}: #{params[:pubid]}")
      render_json
      return
    end
    if publication.published_at
      generate_error(403, "#{I18n.t "publications.errors.delete_only_drafts"}")
      render_json
      return
    end
    if publication.update_attribute(:is_deleted, true)
      render_json
    else
      generate_error(422,"#{I18n.t "publications.errors.delete_error"}: #{params[:pubid]}")
      render_json    
    end
      
  end

  private

  # Returns posts where given person_id is an actor
  def publications_by_actor(person_id: person_id)
    publications = Publication.where('id in (?)', People2publication.where('person_id = (?)', person_id.to_i).map { |p| p.publication_id}).where.not(published_at: nil).where(is_deleted: false)
  end

  # Returns posts where given person_id has created or updated posts
  def publications_by_registrator(username: username)
    Publication.where('pubid in (?)', Publication.where('created_by = (?) or updated_by = (?)', username, username).map { |p| p.pubid}).where.not(published_at: nil).where(is_deleted: false)
  end

  # Returns drafts where given person_id has created or updated posts
  def drafts_by_registrator(username: username)
    publications = Publication.where('pubid in (?)', Publication.where('created_by = (?) or updated_by = (?)', username, username).map { |p| p.pubid}).where(published_at: nil).where(is_deleted: false)
  end


  def handle_file_import raw_xml

    if raw_xml.blank?
      generate_error(422, "#{I18n.t "publications.errors.no_data_in_file"}")
      render_json
      return
    end

    xml = Nokogiri::XML(raw_xml)
    if !xml.errors.empty?
      generate_error(422, "#{I18n.t "publications.errors.invalid_file"}", xml.errors)
      render_json
      return
    end

    # check versions
    version_list = xml.search('//source-app').map do |element|
      element.attr("version").to_f
    end
    version_list = version_list.select! do |version|
      version < 8
    end
    if !version_list.empty?
      generate_error(422, "#{I18n.t "publications.errors.unsupported_endnote_version"}")
      render_json
      return
    end

    record_count = 0
    record_total = 0
    return_pub = {}

    xml.search('//xml/records/record').each do |record|
      record_total += 1
      params[:publication] = {}
      endnote = Endnote.parse(record)
      if endnote
        params[:publication].merge!(endnote.as_json)
      else
        params[:publication][:title] = "[Title not found]"
      end

      create_basic_data
      pub = Publication.new(permitted_params(params))
      if pub.save
        record_count += 1
        if record_count == 1
          return_pub = pub
        end
      else
        generate_error(422, "#{I18n.t "publications.errors.update_error"}", pub.errors)
        render_json
      end
    end
    @response[:publication] = return_pub
    @response[:meta] = {result: {count: record_count, total: record_total}}
    render_json(201)
  end

  def import_file
    handle_file_import params[:file].read
  end


  def create_basic_data
    pubid = Publication.get_next_pubid
    params[:publication][:pubid] = pubid
    params[:publication][:is_deleted] = false
    params[:publication][:publication_type] = nil
  end

  def permitted_params(params)
    params.require(:publication).permit(PublicationType.get_all_fields + global_params)
  end

  # Params which are not defined by publication type
  def global_params
    [:pubid, :publication_type, :is_deleted, :created_by, :updated_by, :content_type, :category_hsv_local => []]
  end

  # Creates connections between people, departments and mpublications for a publication and a people array
  def create_affiliation publication_id, people
    people.each_with_index do |person, i|
      p2p = {person_id: person[:id], position: i+1, departments2people2publications: person[:departments]}
      p2p_obj = People2publication.create({publication_id: publication_id, person_id: p2p[:person_id], position: i + 1})
      department_list = p2p[:departments2people2publications]
      department_list.each.with_index do |d2p2p, j|
        Departments2people2publication.create({people2publication_id: p2p_obj.id, department_id: d2p2p[:id], position: j + 1})
        # Set affiliated flag to true when a person gets a connection to a department.
        Person.find_by_id(person[:id]).update_attribute(:affiliated, true)
      end
    end
  end

  # Returns collection of people including departments for a specific Publication
  def people_for_publication(publication_db_id:)
    p2ps = People2publication.where(publication_id: publication_db_id)
    people = p2ps.map do |p2p|
      person = Person.where(id: p2p.person_id).first.as_json
      department_ids = Departments2people2publication.where(people2publication_id: p2p.id).select(:department_id)
      person['departments'] = Department.where(id: department_ids).as_json
      person
    end

    return people
  end

end
