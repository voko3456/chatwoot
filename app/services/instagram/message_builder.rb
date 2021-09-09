# This class creates both outgoing messages from chatwoot and echo outgoing messages based on the flag `outgoing_echo`
# Assumptions
# 1. Incase of an outgoing message which is echo, source_id will NOT be nil,
#    based on this we are showing "not sent from chatwoot" message in frontend
#    Hence there is no need to set user_id in message for outgoing echo messages.

class Instagram::MessageBuilder < FacebookMessenger::MessageBuilder
  attr_reader :messaging

  def initialize(messaging, inbox, outgoing_echo: false)
    @messaging = messaging
    @inbox = inbox
    @outgoing_echo = outgoing_echo
  end

  def perform
    return if @inbox.channel.reauthorization_required?

    build_message
  rescue Koala::Facebook::AuthenticationError
    Rails.logger.info "Facebook Authorization expired for Inbox #{@inbox.id}"
  rescue StandardError => e
    Sentry.capture_exception(e)
    true
  end

  private

  def attachments
    @messaging[:message][:attachments] || {}
  end

  def message_type
    @outgoing_echo ? :outgoing : :incoming
  end

  def message_source_id
    @outgoing_echo ? recipient_id : sender_id
  end

  def sender_id
    @messaging[:sender][:id]
  end

  def recipient_id
    @messaging[:recipient][:id]
  end

  def message
    @messaging[:message]
  end

  def contact
    @contact ||= @inbox.contact_inboxes.find_by(source_id: message_source_id)&.contact
  end

  def conversation
    @conversation ||= Conversation.find_by(conversation_params) || build_conversation
  end

  def message_content
    @messaging[:message][:text]
  end

  def content_attributes
    { message_id: @messaging[:message][:mid] }
  end

  def build_message
    return if @outgoing_echo && already_sent_from_chatwoot?

    @message = conversation.messages.create!(message_params)

    attachments.each do |attachment|
      process_attachment(attachment)
    end
  end

  def build_conversation
    @contact_inbox ||= contact.contact_inboxes.find_by!(source_id: message_source_id)
    Conversation.create!(conversation_params.merge(
                           contact_inbox_id: @contact_inbox.id
                         ))
  end

  def conversation_params
    {
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      contact_id: contact.id,
      additional_attributes: {
        type: 'instagram_direct_message'
      }
    }
  end

  def message_params
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: message_type,
      source_id: message_source_id,
      content: message_content,
      content_attributes: content_attributes,
      sender: @outgoing_echo ? nil : contact
    }
  end

  def already_sent_from_chatwoot?
    cw_message = conversation.messages.where(
      source_id: nil,
      message_type: 'outgoing',
      content: message_content,
      private: false,
      status: :sent
    ).first
    cw_message.update(content_attributes: content_attributes) if cw_message.present?
    cw_message.present?
  end
end
