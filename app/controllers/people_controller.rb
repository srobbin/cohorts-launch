# frozen_string_literal: true
# FIXME: Refactor and re-enable cop
# rubocop:disable ClassLength, Metrics/AbcSize
class PeopleController < ApplicationController

  before_action :set_person, only: [:show, :edit, :update, :destroy]

  skip_before_action :authenticate_user!, if: :should_skip_janky_auth?
  skip_before_action :verify_authenticity_token, only: [:create, :create_sms]
  helper_method :sort_column, :sort_direction

  # GET /people
  # GET /people.json
  def index
    @verified_types = Person.uniq.pluck(:verified).select(&:present?)
    @people = if params[:tags].blank? || params[:tags] == ''
                Person.paginate(page: params[:page]).order(created_at: :desc)
              else
                tags = Tag.where(name: params[:tags])
                Person.paginate(page: params[:page]).order(created_at: :desc).includes(:tags).where(tags: { id: tags.pluck(:id) })
              end
    @tags = params[:tags].blank? ? '[]' : Tag.where(name: params[:tags].map(&:strip)).to_json(methods: [:value, :label, :type])
  end

  # GET /people/1
  # GET /people/1.json
  def show
    @comment = Comment.new commentable: @person
    @gift_card = GiftCard.new
    @tagging = Tagging.new taggable: @person
    @outgoingmessages = TwilioMessage.where(to: @person.normalized_phone_number).where.not(wufoo_formid: nil)
    @twilio_wufoo_formids = @outgoingmessages.pluck(:wufoo_formid).uniq
    @twilio_wufoo_forms = TwilioWufoo.where(id: @twilio_wufoo_formids)
  end

  # GET /people/new
  def new
    @person = Person.new
  end

  # GET /people/1/edit
  def edit; end

  # POST /people/:person_id/deactivate
  def deactivate
    @person = Person.find_by id: params[:person_id]
    @person.deactivate!('admin_interface')
    flash[:notice] = "#{@person.full_name} deactivated"
    respond_to do |format|
      format.js { render text: "$('#person-#{@person.id}').remove()" }
      format.html { redirect_to people_path }
    end
  end

  # FIXME: Refactor and re-enable cop
  # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength, Rails/TimeZone
  #
  # POST /people/create_sms
  def create_sms
    if params['HandshakeKey'].present?
      unless params['HandshakeKey'].start_with? Cohorts::Application.config.wufoo_handshake_key_prefix
        Rails.logger.warn("[wufoo] received request with invalid handshake. Full request: #{request.inspect}")
        head(403) && return
      end
      render nothing: true
      Rails.logger.info('[wufoo] received a submission from wufoo')
      # @person = Person.initialize_from_wufoo_sms(params)
      new_person = Person.new

      # Save to Person
      new_person.first_name = params['Field275'].strip
      new_person.last_name = params['Field276'].strip
      new_person.address_1 = params['Field268'].strip
      new_person.postal_code = params['Field271'].strip
      new_person.phone_number = params['Field281'].strip

      unless params['Field279'].strip.casecmp('SKIP').zero?
        new_person.email_address = params['Field279'].strip
      end
      # new_person.save
      new_person.primary_device_id = case params['Field39'].upcase.strip
                                     when 'A'
                                       Person.map_device_to_id('Desktop computer')
                                     when 'B'
                                       Person.map_device_to_id('Laptop')
                                     when 'C'
                                       Person.map_device_to_id('Tablet')
                                     when 'D'
                                       Person.map_device_to_id('Smart phone')
                                     else
                                       params['Field39']
                                     end

      new_person.primary_device_description = params['Field21'].strip

      new_person.primary_connection_id = case params['Field41'].upcase.strip
                                         when 'A'
                                           Person.map_connection_to_id('Broadband at home')
                                         when 'B'
                                           Person.map_connection_to_id('Phone plan with data')
                                         when 'C'
                                           Person.map_connection_to_id('Public wi-fi')
                                         when 'D'
                                           Person.map_connection_to_id('Public computer center')
                                         else
                                           params['Field41']
                                         end

      new_person.preferred_contact_method = if params['Field278'].upcase.strip == 'TEXT'
                                              'SMS'
                                            else
                                              'EMAIL'
                                            end

      new_person.verified = 'Verified by Text Message Signup'
      new_person.signup_at = Time.now

      new_person.save
    end
  end
  # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize,  Metrics/MethodLength, Rails/TimeZone

  # FIXME: Refactor and re-enable cop
  # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  #
  # POST /people
  # POST /people.json
  def create
    from_wufoo = false
    if params['HandshakeKey'].present?
      unless params['HandshakeKey'].start_with? Cohorts::Application.config.wufoo_handshake_key_prefix
        Rails.logger.warn("[wufoo] received request with invalid handshake. Full request: #{request.inspect}")
        head(403) && return
      end

      Rails.logger.info('[wufoo] received a submission from wufoo')
      from_wufoo = true
      @person = Person.initialize_from_wufoo(JSON.parse(params.to_json, object_class: OpenStruct))
      unless @person.save
        Rails.logger.warn("Person error: #{@person.errors.inspect}")
      end
      if params['HandshakeKey'].end_with? 'vets-signup'
        va_tag = Tag.where(name: 'VA USE ONLY').first_or_create
        Tagging.create(tag: va_tag, taggable: @person)
      elsif params['Field28'].present?
        tag = Tag.where(name: params['Field28']).first_or_create
        Tagging.create(tag: tag, taggable: @person)
      end
      # Send confirmation text with Twilio
      # begin
      #   @client = Twilio::REST::Client.new(ENV['TWILIO_ACCOUNT_SID'], ENV['TWILIO_AUTH_TOKEN'])
      #   @twilio_message = TwilioMessage.new
      #   @twilio_message.from = ENV['TWILIO_SIGNUP_VERIFICATION_NUMBER']
      #   @twilio_message.to = @person.normalized_phone_number
      #   @twilio_message.body = "Thank you for signing up for the Cohorts! Please text us 'Hello' or 12345 to complete your signup. If you did not sign up, text 'Remove Me' to be removed."
      #
      #   @twilio_message.signup_verify = 'Yes'
      #   @twilio_message.save
      #   @message = @client.messages.create(
      #     from: ENV['TWILIO_SIGNUP_VERIFICATION_NUMBER'],
      #     to: @person.normalized_phone_number,
      #     body: @twilio_message.body
      #     # status_callback: request.base_url + "/twilio_messages/#{@twilio_message.id}/updatestatus"
      #   )
      #   @twilio_message.message_sid = @message.sid
      # rescue Twilio::REST::RequestError => e
      #   error_message = e.message
      #   @twilio_message.error_message = error_message
      #   Rails.logger.warn("[Twilio] had a problem. Full error: #{error_message}")
      #   @person.verified = error_message
      #   @person.save
      # end
      # rubocop:disable Style/CommentIndentation
      # @twilio_message.account_sid = ENV['TWILIO_ACCOUNT_SID']
      # @twilio_message.save
      # rubocop:enable Style/CommentIndentation

    # end
    else
      # creating a person by hand
      @person = Person.new(person_params)
    end

    respond_to do |format|
      if @person.save

        from_wufoo ? format.html { head :created } : format.html { redirect_to @person, notice: 'Person was successfully created.' }
        format.json { render action: 'show', status: :created, location: @person }
      else
        format.html { render action: 'new' }
        format.json { render json: @person.errors, status: :unprocessable_entity }
      end
    end
  end
  # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # PATCH/PUT /people/1
  # PATCH/PUT /people/1.json
  def update
    respond_to do |format|
      if @person.with_user(current_user).update(person_params)
        format.html { redirect_to @person, notice: 'Person was successfully updated.' }
        format.json { head :no_content }
      else
        format.html { render action: 'edit' }
        format.json { render json: @person.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /people/1
  # DELETE /people/1.json
  def destroy
    @person.destroy
    flash[:notice] = "#{@person.full_name} deleted"
    respond_to do |format|
      format.js { render text: "$('#person-#{@person.id}').remove()" }
      format.html { redirect_to people_path }
    end
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def import_csv
    csv = CSV.new(params[:file].read, headers: true).read
    headers = csv.headers.compact
    main_attributes = Person.column_names - %w(id created_at updated_at)
    person_attributes = headers.select { |h| main_attributes.include? h.parameterize('_') }
    extra_headers = headers - person_attributes - ['Tags', 'Screening Date']
    questions = extra_headers.map { |header| Question.find_by(text: header) }.compact
    csv.each do |row|
      # Create person
      person_hash = {}
      person_attributes.each do |a|
        person_hash[a.parameterize('_')] = row[a]
      end
      person = Person.create(person_hash)
      Rails.logger.warn person.errors if person.errors.any?
      # Create tags
      if row['Tags']
        row['Tags'].split('|').each do |tag|
          tag = Tag.where(name: tag).first_or_create
          Tagging.create(taggable: person, tag: tag)
        end
      end
      # Add notes
      if row['Notes']
        Comment.create(
          content: row['Notes'],
          commentable: person,
          user_id: User.find_by(email_address: 'rachael.roueche@adhocteam.us')&.id
        )
      end
      # Add screening date as a notes
      if row['Screening Date']
        Comment.create(
          content: "Screening date: #{row['Screening Date']}",
          commentable: person,
          user_id: User.find_by(email_address: 'rachael.roueche@adhocteam.us')&.id
        )
      end
      # Process remaining headers as answers to existing questions
      questions.each do |question|
        Answer.create(person: person, question: question, value: row[question.text]) unless row[question.text].blank?
      end
    end
    flash[:notice] = 'CSV imported successfully'
    redirect_to action: :index
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  private

    # Use callbacks to share common setup or constraints between actions.
    def set_person
      @person = Person.find(params[:id])
    end

    # Never trust parameters from the scary internet, only allow the white list through.
    def person_params
      params.require(:person).permit(:first_name, :last_name, :verified, :email_address,
        :address_1, :address_2, :city, :state, :postal_code, :geography_id, :primary_device_id,
        :primary_device_description, :secondary_device_id, :secondary_device_description,
        :primary_connection_id, :primary_connection_description, :secondary_connection_id,
        :secondary_connection_description, :phone_number, :participation_type,
        :preferred_contact_method,
        gift_cards_attributes: [:gift_card_number, :expiration_date, :person_id, :notes, :created_by, :reason, :amount, :giftable_id, :giftable_type])
    end

    def should_skip_janky_auth?
      # don't attempt authentication on reqs from wufoo
      (params[:action] == 'create' || params[:action] == 'create_sms') && params['HandshakeKey'].present?
      # params[:action] == 'create_sms' && params['HandshakeKey'].present?
    end

    def sort_column
      res = Person.column_names.include?(params[:sort]) ? params[:sort] : 'id'
      "people.#{res}"
    end

    def sort_direction
      %w(asc desc).include?(params[:direction]) ? params[:direction] : 'desc'
    end

end
# rubocop:enable ClassLength
