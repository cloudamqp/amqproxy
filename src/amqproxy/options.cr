module AMQProxy
  struct Options
    property listen_address : String? = nil
    property listen_port : Int32? = nil
    property http_port : Int32? = nil
    property idle_connection_timeout : Int32? = nil
    property term_timeout : Int32? = nil
    property term_client_close_timeout : Int32? = nil
    property log_level : Log::Severity? = nil
    property? debug : Bool = false
    property ini_file : String? = nil
    property upstream : String? = nil
  end
end
