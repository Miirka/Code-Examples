class Appointment < ActiveRecord::Base
  belongs_to :user
  belongs_to :provider
  belongs_to :service_option
  belongs_to :location
  belongs_to :mobile_coverage
  has_one :payment_record, :dependent => :destroy
  attr_protected :id
  attr_protected :id, as: :admin

  include Rails.application.routes.url_helpers

  STATUSES = {
    unconfirmed:  "To Be Confirmed",
    confirmed:    "Confirmed",
    done:         "Done",
    rescheduled:  "Rescheduled",
    cancelled:    "Cancelled",
    noshow:       "No-Show"
  }

  CATEGORIES = %w{ therapist platform sync}

  scope :before, lambda {|end_time|   { conditions: ["end_time < ?", Appointment.format_date(end_time)] }}
  scope :after,  lambda {|start_time| { conditions: ["start_time > ?", Appointment.format_date(start_time)] }}
  scope :during, lambda {|range| where("start_time < ? AND end_time > ?", range.max, range.min) }
  scope :during_for_calendar, lambda {|start_time, end_time|  where("start_time < ? AND end_time > ?", 
                                                              Appointment.format_date(end_time), 
                                                              Appointment.format_date(start_time))
                                      }
  scope :active, lambda { where(status: %w{unconfirmed confirmed rescheduled}) }
  scope :platform, lambda { where(category: %w{platform}) }
  scope :sync, lambda { where(category: %w{sync}) }
  scope :not_sync_at, lambda {|tag|   { conditions: ["sync_tag != ?", tag] }}
  scope :sync_at, lambda {|tag|   { conditions: ["sync_tag = ?", tag] }}

  before_validation :adjust_time

  validates :status,   inclusion: { in: STATUSES.map {|k, v| k.to_s}, message: "%{value} is not a valid status" }
  validates :category, inclusion: { in: CATEGORIES, message: "%{value} is not a valid type" }
  validates_presence_of :provider
  validates :user, :service_option, presence: true, if: Proc.new { |ap| ap.category == "platform"  }
  validate :location_or_address_present, :provider_is_available, if: Proc.new { |ap| ap.category == "platform"  }
  validates_presence_of :service_starts_at, if: Proc.new { |ap| ap.category == "platform"  }
  
  after_create :add_mobile_coverage

  before_destroy do 
    if self.category == 'platform'
      self.errors.add(:base, "A 'Platform Appointment' cannot be deleted")
      false
    end
  end
  
  after_update do
    process_job?
    notify_about_changes
    payment_record = PaymentRecord.find_by_appointment_id(self.id)
    if self.payment_status == 'paid' && payment_record.status != 'paid'
      payment_record.update_attributes status: 'paid'
    end
    if cancelled?
      payment_record.destroy unless payment_record.status != 'to_be_charged'
    end
  end

  def self.format_date(date_time)
    Time.at(date_time.to_i).utc.to_formatted_s(:db)
  end

  # need to override the json view to return what full_calendar is expecting.
  # http://arshaw.com/fullcalendar/docs/event_data/Event_Object/
  def as_json(options = {})
    if self.category == 'platform' && self.status == 'unconfirmed'
      bck_color = '#d2322d'
      text_color = '#fff'
    elsif self.category == 'platform'
      bck_color = '#60A869'
      text_color = '#004203'
    elsif self.category == 'sync'
      bck_color = '#aaa'
      text_color = '#7e7e7e'
    else
      #bck_color = '#91C9DF'
      #text_color = '#2B6379'
      bck_color = '#808080'
      text_color = '#444444'
    end
    if self.category == 'sync'
      title = 'Busy Time (sync)'
    else
      title = [self.user_name, self.user ? self.user.name : nil, self.therapy_name, self.title, 'Appointment'].reject{ |c| !c.present? }
      title = title[0]
    end
    {
      id:         self.id,
      title:      title,
      address:    self.address || "",
      start:      self.service_starts_at,
      # fullCalendar stores end time as exclusive
      end:        service_ends_at + 1.second,
      color:      bck_color,
      textColor: text_color
    }
  end

  def to_ics
    event = Icalendar::Event.new
    event.uid = self.id.to_s
    start_date = self.service_starts_at
    end_date = self.service_ends_at
    event.dtstart = DateTime.civil(start_date.year, start_date.month, start_date.day, start_date.hour, start_date.min)
    event.dtend = DateTime.civil(end_date.year, end_date.month, end_date.day, end_date.hour, end_date.min)
    if self.status == 'unconfirmed'
      event.summary = "MeTime - TO CONFIRM - #{self.to_s}"
      event.description = self.description
    else
      event.summary = "MeTime - #{self.to_s}"
      event.description = self.description
    end
    loc = self.location_id.nil? ? [self.address.presence, self.postcode.presence].join("-") : self.location.to_s_name_full_address
    event.location = loc if loc != "-"
    event.created = self.created_at
    event.last_modified = self.updated_at
    event.ip_class = "PUBLIC"
    if self.category == 'platform'
      event.alarm do |a|
        a.action  = "DISPLAY"
        a.summary = event.summary
        a.trigger = "-PT30M" # 30mins before
      end
    end
    event
  end

  def to_s
    if self.category == 'platform'
      service_title = self.service_option.service.title
      service_duration = self.service_option.duration
      return "#{service_title} - #{service_duration}mins"
    else
      return self.user_name.presence ? self.user_name : (self.therapy_name.presence ? self.therapy_name : 'Appointment')
    end
  end

  def description
    description = []
    loc = self.location_id.nil? ? [self.address.presence, self.postcode.presence].join("-") : self.location.to_s_name_full_address
    if self.category == 'platform'
      service_type = ServiceType.find(self.provider.service_type_list[0]).name.singularize
      service_title = self.service_option.service.title
      service_duration = self.service_option.duration
      description << "* #{service_type}: #{service_title} - #{service_duration}mins"
      user = self.user
      description << "* Client: #{user.name}"
      description << "* Client's phone numer: #{user.phone_number}"
      description << "* Location: #{loc}"
      description << "* Notes: #{self.title}" if self.title.presence
    else
      description << "* Client: #{self.user_name}" if self.user_name.presence
      description << "* Service: #{self.therapy_name}" if self.therapy_name.presence
      description << "* Location: #{loc}" if loc != "-"
      description << "* Notes: #{self.title}" if self.title.presence
    end
    description.join("\n")
  end

  def add_mobile_coverage
    unless postcode.blank?
      postcode          = self.postcode.split(' ')[0].upcase
      default_postcode  = self.provider.default_postcode
      mobile_coverage   = MobileCoverage.find_by_outcode postcode
      mobile_coverage   = default_postcode if mobile_coverage.blank? && !default_postcode.blank?
      self.update_attributes mobile_coverage_id: mobile_coverage.id unless mobile_coverage.blank?
    end
  end

  def is_past?
    self.start_time < Time.now
  end

  def actual_postcode
    location.try(:postcode) || postcode
  end

  def send_confirmation_notice
    BookingMailer.delay.confirm_appointment(self.user, self.provider, self)
    count_admin = 0
    [User.with_role(:admin), User.with_role(:superadmin)].flatten.each do |admin|
      count_admin += 1
      BookingMailer.delay.notify_admin_new_appointment(admin, self.user, self.provider, self, count_admin)
    end
  end

  def send_provider_SMS_notification
    number = self.provider.user.phone_number
    @sms = Twilio::REST::Client.new TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN
    confirmation_url = appointments_list_url
    @sms.account.messages.create({
      from: TWILIO_NUMBER,
      to:   number,
      body: "MeTime | You have a new appointment! Review and confirm it at the link below:\r\n\r\n#{confirmation_url}",
    })
    rescue Twilio::REST::RequestError => e
      logger.error  "Twilio error while sending therapist appointment notification: #{e.message}"
  end

  private

    def process_job?
      if category == "platform" && rescheduled? || cancelled?
        jobs_proccessing
      end
    end

    def jobs_proccessing
      Delayed::Job.all.each do |job|
        if job.name == "Charge-Appointment-#{self.id}"
          @job = job
        end
      end
      return unless @job
      day_before_appointment = Time.now < @job.run_at
      if rescheduled? && day_before_appointment
        @job.destroy
        # charge_job = Delayed::Job.enqueue( ChargingJob.new(self.id), run_at: self.service_starts_at - 1.day )
        # Changed from 1 day before to 10 minutes after now
        charge_job = Delayed::Job.enqueue( ChargingJob.new(self.id), run_at: Time.now + 10.minutes )
      elsif cancelled? && day_before_appointment
        @job.destroy
      end
    end

    def rescheduled?
      start_time_changed? && status == 'rescheduled'
    end

    def cancelled?
      status_changed? && status == 'cancelled'
    end

    def adjust_time
      if self.all_day
        self.start_time = self.start_time.beginning_of_day
        self.end_time = self.end_time.end_of_day
      end
      if self.category == "platform" && self.service_starts_at
        start_location  = provider.determine_location(self.service_starts_at)
        commute_time    = MobileCoverage.commute_time(start_location, actual_postcode, provider.transport_mode.try(:speed))
        self.start_time = self.service_starts_at - commute_time
        self.end_time   = self.service_starts_at + self.service_option.duration.to_i.minutes + self.service_option.gutter_time.to_i.minutes
        self.service_ends_at = self.service_starts_at + self.service_option.duration.to_i.minutes
      else
        self.service_starts_at = self.start_time
        self.service_ends_at = self.end_time
      end
    end

    def location_or_address_present
      errors.add :location, 'Appointments should have either a location, or a postcode!' if !location && postcode.blank? && category == "platform"
    end

    def provider_is_available
      return if !provider || !start_time || !end_time
      overlappings = provider.appointments.during(start_time..end_time).active
      overlappings = overlappings.where("id != #{self.id}") if self.id
      if self.status == 'rescheduled'
        errors.add :base, 'The new date & time you selected overlap with an existing appointment.' unless overlappings.blank?
      else
        errors.add :base, 'Unfortunately, this appointment time has just been booked! Please select another time :)' unless overlappings.blank?
      end
    end

    def notify_about_changes
      admins = [User.with_role(:admin), User.with_role(:superadmin)].flatten
      count_admin = 0
      if self.status == 'rescheduled' && !self.confirmed
        AppointmentMailer.delay.appointment_rescheduled(self)
        admins.each do |admin|
          count_admin += 1
          AppointmentMailer.delay.admin_appointment_rescheduled(admin, self, count_admin)
        end
      elsif self.status == 'rescheduled' && self.confirmed
        AppointmentMailer.delay.confirmed_appointment_rescheduled(self)
        admins.each do |admin|
          count_admin += 1
          AppointmentMailer.delay.admin_confirmed_appointment_rescheduled(admin, self, count_admin)
        end
      elsif self.status == 'cancelled' && !self.confirmed
        AppointmentMailer.delay.appointment_cancelled(self)
        admins.each do |admin|
          count_admin += 1
          AppointmentMailer.delay.admin_appointment_cancelled(admin, self, count_admin)
        end
      elsif self.status == 'cancelled' && self.confirmed
        AppointmentMailer.delay.confirmed_appointment_cancelled(self)
        admins.each do |admin|
          count_admin += 1
          AppointmentMailer.delay.admin_confirmed_appointment_cancelled(admin, self, count_admin)
        end
      end
    end

end