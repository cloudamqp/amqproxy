module AMQProxy
  record Options,
         listen_address : String? = nil,
         listen_port : Int32? = nil,
         http_port : Int32? = nil,
         idle_connection_timeout : Int32? = nil,
         term_timeout : Int32? = nil,
         term_client_close_timeout : Int32? = nil,
         log_level : Log::Severity? = nil,
         is_debug : Bool = false,
         ini_file : String? = nil,
         upstream : String? = nil do
  
    # Define `with` method to allow selective modifications
    def with(
      listen_address : String? = self.listen_address,
      listen_port : Int32? = self.listen_port,
      http_port : Int32? = self.http_port,
      idle_connection_timeout : Int32? = self.idle_connection_timeout,
      term_timeout : Int32? = self.term_timeout,
      term_client_close_timeout : Int32? = self.term_client_close_timeout,
      log_level : Log::Severity? = self.log_level,
      is_debug : Bool = self.is_debug,
      ini_file : String? = self.ini_file,
      upstream : String? = self.upstream
    )
      Options.new(
        listen_address,
        listen_port,
        http_port,
        idle_connection_timeout,
        term_timeout,
        term_client_close_timeout,
        log_level,
        is_debug,
        ini_file,
        upstream
      )
    end
  end    
end
