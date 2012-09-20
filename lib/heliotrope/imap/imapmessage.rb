class IMAPMessage

  attr_reader :uid

  def initialize uid, mail_store
    @uid = uid
    @mail_store = mail_store
  end

  def flags
    @mail_store.fetch_labels_and_flags_for_message_id @uid
  end

  def seqno_in(mailbox_name)
    @seqno ||= @mail_store.get_seqno mailbox_name, @uid
  end

  def rawbody
    @rawbody ||= @mail_store.fetch_raw @uid
  end

end