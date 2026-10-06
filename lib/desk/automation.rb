# frozen_string_literal: true

module Desk
  # Marks code that runs without a person: the desk's jobs and the AI calls. Desk::Sender refuses to run inside it,
  # so no automated path can send a document, whatever the AI returns or a job is asked to do.
  module Automation
    module_function

    def run
      previous = Thread.current[:desk_automation]
      Thread.current[:desk_automation] = true

      yield
    ensure
      Thread.current[:desk_automation] = previous
    end

    def active? = Thread.current[:desk_automation] == true
  end
end
