# == Schema Information
#
# Table name: reservations
#
#  id           :integer          not null, primary key
#  person_id    :integer
#  time_slot_id :integer
#

require 'faker'

FactoryGirl.define do
  factory :reservation, class: V2::Reservation do
    before(:create) do |reservation|
      reservation.person =  FactoryGirl.create(:person)
      reservation.time_slot = FactoryGirl.create(:time_slot)
    end
  end
end
