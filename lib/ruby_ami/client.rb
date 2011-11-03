module RubyAMI
  class Client
    attr_reader :options, :action_queue, :events_stream, :actions_stream

    def initialize(options)
      @options          = options
      @state            = :stopped

      @actions_write_blocker = CountDownLatch.new 1

      @pending_actions  = {}
      @sent_actions     = {}
      @actions_lock     = Mutex.new

      @action_queue = GirlFriday::WorkQueue.new(:actions, :size => 1, :error_handler => ErrorHandler) do |action|
        @actions_write_blocker.wait
        _send_action action
        action.response
      end

      @message_processor = GirlFriday::WorkQueue.new(:messages, :size => 2, :error_handler => ErrorHandler) do |message|
        handle_message message
      end

      @event_processor = GirlFriday::WorkQueue.new(:events, :size => 2, :error_handler => ErrorHandler) do |event|
        handle_event event
      end
    end

    [:started, :stopped, :ready].each do |state|
      define_method("#{state}?") { @state == state }
    end

    def start
      EventMachine.run do
        yield
        @events_stream  = start_stream lambda { |event| @event_processor << event }
        @actions_stream = start_stream lambda { |message| @message_processor << message }
        @state = :started
      end
    end

    def send_action(action, headers = {}, &block)
      (action.is_a?(Action) ? action : Action.new(action, headers, &block)).tap do |action|
        register_pending_action action
        action_queue << action
      end
    end

    def handle_message(message)
      case message
      when Stream::Connected
        start_writing_actions
        login_actions
      when Response
        action = sent_action_with_id message.action_id
        if action
          message.action = action
          action << message
        else
          raise "Received an AMI response with an unrecognized ActionID!! This may be an bug! #{message.inspect}"
        end
      end
    end

    def handle_event(event)
      login_events if event.is_a? Stream::Connected
    end

    def _send_action(action)
      transition_action_to_sent action
      actions_stream.send_action action
      action.state = :sent
    end

    private

    def register_pending_action(action)
      @actions_lock.synchronize do
        @pending_actions[action.action_id] = action
      end
    end

    def transition_action_to_sent(action)
      @actions_lock.synchronize do
        @pending_actions.delete action.action_id
        @sent_actions[action.action_id] = action
      end
    end

    def sent_action_with_id(action_id)
      @actions_lock.synchronize do
        @sent_actions.delete action_id
      end
    end

    def start_writing_actions
      @actions_write_blocker.countdown!
    end

    def login_actions
      @action_queue << login_action
    end

    def login_events
      login_action('On').tap do |action|
        events_stream.send_action action
      end
    end

    def login_action(events = 'Off')
      Action.new 'Login',
                 'Username' => options[:username],
                 'Secret' => options[:password],
                 'Events' => events
    end

    def start_stream(callback)
      Stream.start @options[:server], @options[:port], callback
    end

    class ErrorHandler
      def handle(error)
        puts error
        puts error.backtrace.join("\n")
      end
    end
  end
end
