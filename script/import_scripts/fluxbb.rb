# frozen_string_literal: true

require "mysql2"

require File.expand_path(File.dirname(__FILE__) + "/base.rb")

# Before running this script, paste these lines into your shell,
# then use arrow keys to edit the values
=begin
export FLUXBB_HOST="localhost"
export FLUXBB_DB="fluxbb"
export FLUXBB_USER="root"
export FLUXBB_PW=""
export FLUXBB_PREFIX=""
=end

# Call it like this:
#   RAILS_ENV=production bundle exec ruby script/import_scripts/fluxbb.rb
class ImportScripts::FluxBB < ImportScripts::Base
  FLUXBB_HOST ||= ENV["FLUXBB_HOST"] || "localhost"
  FLUXBB_DB ||= ENV["FLUXBB_DB"] || "fluxbb"
  BATCH_SIZE ||= 1000
  FLUXBB_USER ||= ENV["FLUXBB_USER"] || "root"
  FLUXBB_PW ||= ENV["FLUXBB_PW"] || ""
  FLUXBB_PREFIX ||= ENV["FLUXBB_PREFIX"] || ""

  # Set this if you want to rewrite relative links to be absolute.
  # e.g. "https://mysite.com/old-forum-redirector/"
  FLUXBB_RELATIVE_LINKS_BASE ||= ENV['FLUXBB_RELATIVE_LINKS_BASE'] || ""

  CREATE_PERMALINKS = true

  def initialize
    super

    @client =
      Mysql2::Client.new(
        host: FLUXBB_HOST,
        username: FLUXBB_USER,
        password: FLUXBB_PW,
        database: FLUXBB_DB,
      )
  end

  def execute
    import_groups
    import_users
    import_categories
    import_posts
    suspend_users
    create_permalinks if CREATE_PERMALINKS
  end

  def import_groups
    puts "", "creating groups"

    results =
      mysql_query(
        "SELECT g_id id, g_title name, g_user_title title
       FROM #{FLUXBB_PREFIX}groups",
      )

    customgroups = results.select { |group| group["id"] > 2 }

    create_groups(customgroups) do |group|
      { id: group["id"], name: group["name"], title: group["title"] }
    end
  end

  def import_users
    puts "", "creating users"

    total_count = mysql_query("SELECT count(*) count FROM #{FLUXBB_PREFIX}users;").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "SELECT id, username, realname name, url website, email email, registered created_at,
                registration_ip registration_ip_address, last_visit last_visit_time,
                last_email_sent last_emailed_at, location, group_id
         FROM #{FLUXBB_PREFIX}users
         LIMIT #{BATCH_SIZE}
         OFFSET #{offset};",
        )

      break if results.size < 1

      next if all_records_exist? :users, results.map { |u| u["id"].to_i }

      create_users(results, total: total_count, offset: offset) do |user|
        {
          id: user["id"],
          email: user["email"],
          username: user["username"],
          name: user["name"],
          created_at: Time.zone.at(user["created_at"]),
          website: user["website"],
          registration_ip_address: user["registration_ip_address"],
          last_seen_at: Time.zone.at(user["last_visit_time"]),
          last_emailed_at:
            user["last_emailed_at"] == nil ? 0 : Time.zone.at(user["last_emailed_at"]),
          location: user["location"],
          moderator: user["group_id"] == 2,
          admin: user["group_id"] == 1,
        }
      end

      groupusers = results.select { |user| user["group_id"] > 2 }

      groupusers.each do |user|
        if user["group_id"]
          user_id = user_id_from_imported_user_id(user["id"])
          group_id = group_id_from_imported_group_id(user["group_id"])

          GroupUser.find_or_create_by(user_id: user_id, group_id: group_id) if user_id && group_id
        end
      end
    end
  end

  def import_categories
    puts "", "importing top level categories..."

    categories =
      mysql_query(
        "
                              SELECT id, cat_name name, disp_position position
                              FROM #{FLUXBB_PREFIX}categories
                              ORDER BY id ASC
                            ",
      ).to_a

    create_categories(categories) { |category| { id: category["id"], name: category["name"] } }

    puts "", "importing children categories..."

    children_categories =
      mysql_query(
        "
                                       SELECT id, forum_name name, forum_desc description, disp_position position, cat_id parent_category_id
                                       FROM #{FLUXBB_PREFIX}forums
                                       ORDER BY id
                                      ",
      ).to_a

    create_categories(children_categories) do |category|
      {
        id: "child##{category["id"]}",
        name: category["name"],
        description: category["description"],
        parent_category_id: category_id_from_imported_category_id(category["parent_category_id"]),
      }
    end
  end

  def import_posts
    puts "", "creating topics and posts"

    total_count = mysql_query("SELECT count(*) count from #{FLUXBB_PREFIX}posts").first["count"]

    batches(BATCH_SIZE) do |offset|
      results =
        mysql_query(
          "
        SELECT p.id id,
               t.id topic_id,
               t.forum_id category_id,
               t.subject title,
               t.first_post_id first_post_id,
               p.poster_id user_id,
               p.message raw,
               p.posted created_at
        FROM #{FLUXBB_PREFIX}posts p,
             #{FLUXBB_PREFIX}topics t
        WHERE p.topic_id = t.id
        ORDER BY p.posted
        LIMIT #{BATCH_SIZE}
        OFFSET #{offset};
      ",
        ).to_a

      break if results.size < 1
      next if all_records_exist? :posts, results.map { |m| m["id"].to_i }

      create_posts(results, total: total_count, offset: offset) do |m|
        skip = false
        mapped = {}

        mapped[:id] = m["id"]
        mapped[:user_id] = user_id_from_imported_user_id(m["user_id"]) || -1
        mapped[:raw] = process_fluxbb_post(m["raw"], m["id"])
        mapped[:created_at] = Time.zone.at(m["created_at"])

        if m["id"] == m["first_post_id"]
          mapped[:category] = category_id_from_imported_category_id("child##{m["category_id"]}")
          mapped[:title] = CGI.unescapeHTML(m["title"])
        else
          parent = topic_lookup_from_imported_post_id(m["first_post_id"])
          if parent
            mapped[:topic_id] = parent[:topic_id]
          else
            puts "Parent post #{m["first_post_id"]} doesn't exist. Skipping #{m["id"]}: #{m["title"][0..40]}"
            skip = true
          end
        end

        skip ? nil : mapped
      end
    end
  end

  def suspend_users
    puts "", "updating banned users"

    banned = 0
    failed = 0
    total = mysql_query("SELECT count(*) count FROM #{FLUXBB_PREFIX}bans").first["count"]

    system_user = Discourse.system_user

    mysql_query("SELECT username, email FROM #{FLUXBB_PREFIX}bans").each do |b|
      user = User.find_by_email(b["email"])
      if user
        user.suspended_at = Time.now
        user.suspended_till = 200.years.from_now

        if user.save
          StaffActionLogger.new(system_user).log_user_suspend(user, "banned during initial import")
          banned += 1
        else
          puts "Failed to suspend user #{user.username}. #{user.errors.try(:full_messages).try(:inspect)}"
          failed += 1
        end
      else
        puts "Not found: #{b["email"]}"
        failed += 1
      end

      print_status banned + failed, total
    end
  end

  def process_fluxbb_post(raw, import_id)
    s = raw.dup

    unless FLUXBB_RELATIVE_LINKS_BASE.blank?
      s.gsub!(/\[url\]\s*\//i, "[url]#{FLUXBB_RELATIVE_LINKS_BASE}")
      s.gsub!(/\[url=\s*\/(.*)\s*\]/i, "[url=#{FLUXBB_RELATIVE_LINKS_BASE}\\1]")
    end

    # FluxBB supports slightly different smiley character combos vs discourse
    s.gsub!(/(\s)=\)/, "\\1:)")
    s.gsub!(/(\s)=\|/, "\\1:|")
    s.gsub!(/(\s)=\(/, "\\1:(")
    s.gsub!(/(\s)=D/, "\\1:D")
    s.gsub!(/(\s):o/, "\\1:O")
    s.gsub!(/(\s):lol:/, '\\1:laughing:')
    s.gsub!(/(\s):mad:/, '\\1:rage:')
    s.gsub!(/(\s):rolleyes:/, '\\1:roll_eyes:')
    s.gsub!(/(\s):cool:/, '\\1:sunglasses:')

    # Inside [list] tags convert [*][/*] to <li></li>
    s.gsub!(/\[list(?:=.)?\](.*?)\[\/list\]/im) do |list_contents|
      list_contents
        .gsub(/\[\*\](.*?)\[\/\*\]/m, '<li>\1</li>')
        .gsub(/\[\*\]/m, '<li>') # Unclosed [*] are also allowed
    end
    # convert [list] tags to <ul> and [list=1] tags to <ol>
    s.gsub!(/\[list\](.*?)\[\/list\]/im, '<ul>\1</ul>')
    s.gsub!(/\[list=1\](.*?)\[\/list\]/im, '<ol>\1</ol>')
    s.gsub!(/\[list=a\](.*?)\[\/list\]/im, '<ol class="alpha">\1</ol>')
    s.gsub!(/\[list=\*\](.*?)\[\/list\]/im, '<ol>\1</ol>')

    # FluxBB uses [code] for code blocks, Discourse uses <pre>
    s.gsub!(/\[code\](.*?)\[\/code\]/im, '<pre>\1</pre>')

    # :) is encoded as <!-- s:) --><img src="{SMILIES_PATH}/icon_e_smile.gif" alt=":)" title="Smile" /><!-- s:) -->
    s.gsub!(/<!-- s(\S+) -->(?:.*)<!-- s(?:\S+) -->/, '\1')

    # Some links look like this: <!-- m --><a class="postlink" href="http://www.onegameamonth.com">http://www.onegameamonth.com</a><!-- m -->
    s.gsub!(%r{<!-- \w --><a(?:.+)href="(\S+)"(?:.*)>(.+)</a><!-- \w -->}, '[\2](\1)')

    # Many bbcode tags have a hash attached to them. Examples:
    #   [url=https&#58;//google&#46;com:1qh1i7ky]click here[/url:1qh1i7ky]
    #   [quote=&quot;cybereality&quot;:b0wtlzex]Some text.[/quote:b0wtlzex]
    s.gsub!(/:(?:\w{8})\]/, "]")

    # Remove video tags.
    s.gsub!(%r{(^\[video=.*?\])|(\[/video\]$)}, "")

    s = CGI.unescapeHTML(s)

    # shortens link text like this, which breaks our markdown processing:
    #   [http://answers.yahoo.com/question/index ... 223AAkkPli](http://answers.yahoo.com/question/index?qid=20070920134223AAkkPli)
    #
    # Work around it for now:
    s.gsub!(%r{\[http(s)?://(www\.)?}, "[")

    s
  end

  def bbcode_tag_additions_and_overrides
    link_base = FLUXBB_RELATIVE_LINKS_BASE.blank? ? "/" : FLUXBB_RELATIVE_LINKS_BASE

    {
      h: {
        html_open: "\n## ", html_close: "\n",
        newlines: :to_br,
        description: 'Make a heading',
        example: '[h]My Heading[/h]' },
      del: {
        html_open: '<del>', html_close: '</del>',
        description: 'Deleted text',
        example: 'This is [del]deleted[/del].' },
      ins: {
        html_open: '<ins>', html_close: '</ins>',
        description: 'Inserted text',
        example: 'This is [ins]inserted[/ins].' },
      em: {
        html_open: '**', html_close: '**',
        description: 'Make text emphasised (same as bold in markdown)',
        example: 'This is [em]emphasised[/em].' },
      img: {
        html_open: '<img src="%between%"%alt_text%/>', html_close: '',
        description: 'Image',
        example: '[img=my alt text]http://www.google.com/intl/en_ALL/images/logo.gif[/img].',
        only_allow: [],
        require_between: true,
        allow_tag_param: true, allow_tag_param_between: false,
        tag_param: /(.*)/,
        tag_param_tokens: [{ token: :alt_text, prefix: ' alt="', postfix: '"' }],
        tag_param_description: 'The img bbcode takes alt text as a parameter' },
      post: {
        html_open: '[%between%](%post_url%#p%post_id%)', html_close: '',
        description: 'Link to forum post by id',
        example: '[post=1]Link text[/post].',
        only_allow: [],
        require_between: true,
        allow_tag_param: true,
        allow_tag_param_between: true,
        tag_param: /((\d*))/,
        tag_param_tokens: [ { token: :post_id },
                            { token: :post_url, prefix: "#{link_base}viewtopic.php?pid=" }] },
      topic: {
        html_open: '[%between%](%topic_url%)', html_close: '',
        description: 'Link to forum topic by id',
        example: '[topic=1]Link text[/topic].',
        only_allow: [],
        require_between: true,
        allow_tag_param: true,
        allow_tag_param_between: true,
        tag_param: /(\d*)/,
        tag_param_tokens: [ { token: :topic_url, prefix: "#{link_base}viewtopic.php?id=" }] },
      forum: {
        html_open: '[%between%](%forum_url%)', html_close: '',
        description: 'Link to forum by id',
        example: '[forum=1]Link text[/forum].',
        only_allow: [],
        require_between: true,
        allow_tag_param: true,
        allow_tag_param_between: true,
        tag_param: /(\d*)/,
        tag_param_tokens: [ { token: :forum_url, prefix: "#{link_base}viewforum.php?id=" }] },
      user: {
        html_open: '[%between%](%user_url%)', html_close: '',
        description: 'Link to user profile by id',
        example: '[user=1]Link text[/user].',
        only_allow: [],
        require_between: true,
        allow_tag_param: true,
        allow_tag_param_between: true,
        tag_param: /(\d*)/,
        tag_param_tokens: [{ token: :user_url, prefix: "#{link_base}profile.php?id=" }] },
    }
  end

  def create_permalinks
    puts '', 'Creating redirects...', ''

    User.find_each do |user|
      ucf = user.custom_fields
      if ucf && ucf["import_id"]
        old_user_profile_url = "profile.php?id=#{ucf['import_id']}"
        new_discourse_user_profile_url = "/u/#{user.username}"
        Permalink.create(url: old_user_profile_url, external_url: new_discourse_user_profile_url)
      end
    end

    Post.find_each do |post|
      pcf = post.custom_fields
      if pcf && pcf["import_id"]
        old_post_url = "viewtopic.php?pid=#{pcf["import_id"]}"
        Permalink.create(url: old_post_url, post_id: post.id)
      end

      if post.post_number == 1
        topic = post.topic_id
        tcf = post.meta_data
        if tcf && tcf["import_topic_id"]
          old_topic_url = "viewtopic.php?id=#{tcf['import_topic_id']}"
          Permalink.create(url: old_topic_url, topic_id: topic)
        end
      end
    end

    Category.find_each do |cat|
      ccf = cat.custom_fields
      if ccf && ccf["import_id"]
        old_forum_id = ccf["import_id"].sub("child#", "")
        old_forum_url = "viewforum.php?id=#{old_forum_id}"
        Permalink.create(url: old_forum_url, category_id: cat.id)
      end
    end
  end

  def mysql_query(sql)
    @client.query(sql, cache_rows: false)
  end
end

ImportScripts::FluxBB.new.perform
