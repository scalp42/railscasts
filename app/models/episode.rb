class Episode < ActiveRecord::Base

  include PgSearch

  has_many :comments, :dependent => :destroy
  has_many :taggings, :dependent => :destroy
  has_many :tags, :through => :taggings
  has_many :assets, :as => :assetable, :dependent => :destroy 
  belongs_to :user 
  
  accepts_nested_attributes_for :assets, :allow_destroy => true

  has_paper_trail
  
  has_attached_file :icon, 
    :styles => { normal: "204x140", mini_thumb: "45x45"},
    :url => ":id/:style_:basename.:extension",
    :path => ":id/:style_:basename.:extension",
    :storage => :s3,
    :s3_credentials => { :access_key_id     => APP_CONFIG['s3_key'],
                         :secret_access_key => APP_CONFIG['s3_secret'] },
    :bucket => "ms_#{Rails.env}_episode_icons"

  scope :published, lambda { where('published_at <= ?', Time.now.utc) }
  scope :unpublished, lambda { where('published_at > ?', Time.now.utc) }
  scope :tagged, lambda { |tag_id| tag_id ? joins(:taggings).where(:taggings => {:tag_id => tag_id}) : scoped }
  scope :recent, order('position DESC')  

  pg_search_scope :search_by_content, :against => [:notes, :name, :description]

  validates_presence_of :published_at, :name
  #serialize :file_sizes

  before_create :set_permalink
  
  TYPES = ["Article", "Video", "Gallery"]

  # sometimes ThinkingSphinx isn't loaded for rake tasks
  if respond_to? :define_index
    define_index do
      indexes :name
      indexes position, :sortable => true
      indexes description
      indexes notes
      indexes comments.content, :as => :comment_content
      indexes tags(:name), :as => :tag_names

      has published_at
      has taggings.tag_id, :as => :tag_ids
    end
  end
  
  def new? 
    self.published_at >= 15.days.ago 
  end
  
  def author   
    if self.user.present? 
        self.user         
    else 
       User.find_by_admin(true)
    end 
  end 
  
  def self.search_published(query, tag_id = nil)
    #if APP_CONFIG['thinking_sphinx']
    #  with = tag_id ? {:tag_ids => tag_id.to_i} : {}
    #  search(query, :conditions => { :published_at => 0..Time.now.utc.to_i }, :with => with,
    #                :field_weights => { :name => 20, :description => 15, :notes => 5, :tag_names => 10 })
    #else
      published.search_by_content(query)
    #end
  #rescue ThinkingSphinx::ConnectionError => e
    #APP_CONFIG['thinking_sphinx'] = false
    #raise e
  end

  def self.primitive_search(query, join = "AND")
    where(primitive_search_conditions(query, join))
  end

  def similar_episodes
    #if APP_CONFIG['thinking_sphinx']
    #  self.class.search("#{name} #{tag_names}", :without_ids => [id],
    #        :conditions => { :published_at => 0..Time.now.utc.to_i },
    #        :match_mode => :any, :page => 1, :per_page => 5,
    #        :field_weights => { :name => 20, :description => 15, :notes => 5, :tag_names => 10 })
    #else
      # Search by the first tag name wow this is terrible 
      self.class.published.where("id != ?", self.id).search_by_content(self.tags.first.name).limit(5)
    #end
  #rescue ThinkingSphinx::ConnectionError => e
   # APP_CONFIG['thinking_sphinx'] = false
   # raise e
  end
  
  def type 
    self.class::TYPES[self.type_id]
  end 
  
  def duration
    if self.type == "Video"
        pluralize (@episode.seconds/60).round, "minute"
    end 
  end 
  
  def link_text 
    case self.type 
    when "Video" 
        "Watch Episode" 
    when "Article" 
        "Read Article" 
    when "Gallery"
        "View Gallery" 
    else
        "View Episode" 
    end
  end 
  
  def tab_text 
    case self.type 
    when "Video" 
        "Show Notes" 
    when "Article" 
        "Article" 
    when "Gallery"
        "Gallery Photos" 
    else
        "Notes" 
    end
  end 

  def full_name
    "\##{position} #{name}"
  end

  def tag_names=(names)
    self.tags = Tag.with_names(names.split(/\s+/))
  end

  def tag_names
    tags.map(&:name).join(' ')
  end

  def to_param
    [position, permalink].join('-')
  end

  def asset_name
    [padded_position, permalink].join('-')
  end

  def asset_url(path, ext = nil)
    "videos/#{asset_name}" + (ext ? ".#{ext}" : "")
  end

  def padded_position
    position.to_s.rjust(3, "0")
  end

  def last_published?
    self == self.class.published.last
  end

  def published?
    published_at <= Time.zone.now
  end

  def duration
    if seconds
      min, sec = *seconds.divmod(60)
      [min, sec.to_s.rjust(2, '0')].join(':')
    end
  end

  def duration=(duration)
    if duration.present?
      min, sec = *duration.split(':').map(&:to_i)
      self.seconds = min*60 + sec
    end
  end

  def self.find_by_param!(param)
    find_by_position!(param.to_i)
  end

  def files
    [
      {:name => "source code", :info => "Project Files in Zip",   :url => asset_url("sources", "zip"),    :size => file_size("zip")},
      {:name => "mp4",         :info => "Full Size H.264 Video",  :url => asset_url("videos", "mp4"),  :size => file_size("mp4")},
      {:name => "m4v",         :info => "Smaller H.264 Video",    :url => asset_url("videos", "m4v"),  :size => file_size("m4v")},
      {:name => "webm",        :info => "Full Size VP8 Video",    :url => asset_url("videos", "webm"), :size => file_size("webm")},
      {:name => "ogv",         :info => "Full Size Theora Video", :url => asset_url("videos", "ogv"),  :size => file_size("ogv")},
    ]
  end

  def file_size(ext)
    (file_sizes && file_sizes[ext]).to_i
  end

  # TODO test me
  def available_files
    files.select { |f| f[:size].to_i > 0 }
  end

  def load_file_sizes
    self.file_sizes = {}
    files.each do |file|
      ext = file[:url][/\w+$/]
      #self.file_sizes[ext] = fetch_file_size(file[:url])
    end
  end

  def fetch_file_size(path)
    url = URI.parse(path)
    response = Net::HTTP.start(url.host, url.port) do |http|
      http.request_head(url.path)
    end
    if response.code == "200"
      response["content-length"]
    end
  end

  def previous
    self.class.where("position < ?", position).order("position desc").first
  end

  def next
    self.class.where("position > ?", position).order("position").first
  end

  private

  def self.primitive_search_conditions(query, join)
    query.split(/\s+/).map do |word|
      '(' + %w[name description notes].map { |col| "#{col} LIKE #{sanitize('%' + word.to_s + '%')}" }.join(' OR ') + ')'
    end.join(" #{join} ")
  end

  def set_permalink
    self.permalink = name.downcase.gsub(/[^0-9a-z]+/, ' ').strip.gsub(' ', '-') if name
  end
end
