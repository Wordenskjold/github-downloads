require 'restclient'
require 'simpleconsole'
require 'json'
require 'mime/types'
require 'cgi'
require 'hpricot'
require 'open-uri'
require 'ostruct'
require 'hirb'

module GithubUploads
  class Manager < SimpleConsole::Controller
    include Hirb::Console
    
    params :string => { 
      :l => :login, 
      :t => :token, 
      :f => :file, 
      :n => :name, 
      :r => :repo,
      :d => :description,
      :p => :proxy
    }
    
    before_filter :set_authentication_params
    
    def default
      puts "Valid actions: list, upload, delete"
      exit 1
    end
    
    def list
      if params[:repo].nil?
        fail! "* Please specify a repository (-r or --repo)"
      end

      downloads = (fetch_downloads(params[:repo]) / "#manual_downloads li").map do |item|
        Download.parse_html(item)
      end

      table downloads, {:fields => [:filename, :description, :size, :uploaded]}
    end
    
    def upload
      if params[:file].nil?
        fail! "* A file must be specified (-f or --file)"
      end
      
      if params[:repo].nil?
        fail! "* A repository (e.g. username/reponame) must be specified (-r or --repo)"
      end
      
      uploader = Uploader.new(@login, @token)
      uploader.proxy = params[:proxy]
      
      if uploader.upload(params[:file], params[:repo], params[:description], params[:name])
        puts "Upload successful!"
      else
        fail! "Upload failed!"
      end
    end
    
    def delete
      if params[:name].nil?
        fail! "* The name of the file to delete must be specified (-n or --name)"
      end
      
      
    end
    
    private
    
    def fail!(message, status = 1)
      puts(message) && exit(status)
    end
    
    def fetch_downloads(repo)
       Hpricot(open("https://github.com/#{repo}/downloads"))
    end
    
    def set_authentication_params
      @login = params[:login] || `git config --global github.user`.strip 
      @token = params[:token] || `git config --global github.token`.strip

      unless @login && @token
        puts "Github login and token must be set using either git config or by using command line options."
        exit 1
      end
    end
  end
  
  class Download < OpenStruct
    def self.parse_html(item)
      new.tap do |download|
        link = item.search("h4 a")
        download.filename = link.inner_html
        download.description = item.search("h4").inner_html.gsub(link.to_s, "").gsub("—", "").strip
        download.size = item.search("p strong").inner_html
        download.uploaded = item.search("time").inner_html
      end
    end
  end
  
  class Uploader
    attr_accessor :proxy
    
    def initialize(login, token)
      @login, @token = login, token
    end
    
    def upload(local_path, repository, description = "", uploaded_file_name = nil)
      file_name = uploaded_file_name || File.basename(local_path)
      
      RestClient.proxy = self.proxy
      
      response = RestClient.post("https://github.com/#{repository}/downloads", {
        :file_size    => File.size(local_path),
        :content_type => mime_type_for_file(local_path).simplified,
        :file_name    => file_name,
        :description  => description,
        :login        => @login,
        :token        => @token
      })

      case response.code
      when 200
        do_s3_upload(local_path, file_name, JSON.parse(response.body))
      else
        puts "Error uploading to Github! (#{response.body})"
        return false
      end
    rescue RestClient::UnprocessableEntity => e
      puts "Error uploading to Github! (file already exists)"
      return false
    end
    
    private
    
    def mime_type_for_file(path)
      MIME::Types.type_for(path)[0] || MIME::Types["application/octet-stream"][0]
    end
    
    def do_s3_upload(local_path, file_name, github_file_data)
      # using an array of arrays because param order is important;
      # anything after the 'file' parameter is ignored by Amazon S3
      response = RestClient.post("http://github.s3.amazonaws.com/", [
        ["key", "#{github_file_data["prefix"]}#{file_name}"],
        ["Filename", file_name],
        ["policy", github_file_data["policy"]],
        ["AWSAccessKeyId", github_file_data["accesskeyid"]],
        ["signature", github_file_data["signature"]],
        ["acl", github_file_data["acl"]],
        ["success_action_status", 201],
        ["Content-Type", ""],
        ["file", File.open(local_path)]
      ])
      
      case response.code
      when 201
        return true
      else
        puts "Error uploading to Amazon S3 (#{response.body})"
        return false
      end
    rescue RestClient::Exception => e
      puts "Error uploading to Amazon S3 (#{e.response.body})"
      return false
    end
  end
end
