# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvaore Sanfilippo.

require 'rubygems'
require 'json'
require 'redis'

class RedisComments
    def initialize(redis,namespace,sort_proc=nil)
        @r = redis
        @namespace = namespace
        @sort_proc = sort_proc
    end

    def thread_key(thread_id)
        "thread:#{@namespace}:#{thread_id}"
    end
    
    def insert(thread_id,comment)
        raise "no parent_id field" if !comment.has_key?('parent_id')
        key = thread_key(thread_id)
        id = @r.hincrby(key,:nextid,1)
        @r.hset(key,id,comment.to_json)
        return id.to_i
    end

    def edit(thread_id,comment_id,comment)
        key = thread_key(thread_id)
        old = @r.hget(key,id)
        return false if !old
        comment['parent_id'] = JSON.parse(old)['parent_id']
        @r.hset(key,id,comment.to_json)
        return true
    end

    def remove_thread(thread_id)
        @r.del(thread_key(thread_id))
    end

    def comments_in_thread(thread_id)
        @r.hlen(thread_key(thread_id)).to_i-1
    end

    def del_comment(thread_id,comment_id)
        # TODO? You may want to make sure there are no parents.
        # If there are parents we can call edit() with "comment removed"
        # or something like that.
        #
        # A probably wiser implementation is to *never* use this method
        # and instead flag the comment as deleted. Then when rendering we
        # can display it in a special way if there are replies, otherwise
        # we can avoid displaying deleted comments that are leafs.
        @r.hdel(thread_key(thread_id),comment_id)
    end

    def render_comments(thread_id,&block)
        byparent = {}
        @r.hgetall(thread_key(thread_id)).each{|id,comment|
            next if id == "nextid"
            c = JSON.parse(comment)
            c['id'] = id.to_i
            parent_id = c['parent_id'].to_i
            byparent[parent_id] = [] if !byparent.has_key?(parent_id)
            byparent[parent_id] << c
        }
        render_comments_rec(byparent,-1,0,block)
    end

    def render_comments_rec(byparent,parent_id,level,block)
        thislevel = byparent[parent_id]
        thislevel = @sort_proc.call(thislevel,level) if @sort_proc
        thislevel.each{|c|
            c['level'] = level
            block.call(c)
            if byparent[c['id']]
                render_comments_rec(byparent,c['id'],level+1,block)
            end
        }
    end
end

# In this example we want comments at top level sorted in reversed chronological
# order, but all the sub trees sorted in plain chronological order.
comments = RedisComments.new(Redis.new,"mycomments",proc{|c,level|
    if level == 0
        c.sort {|a,b| b['ctime'] <=> a['ctime']}
    else
        c.sort {|a,b| a['ctime'] <=> b['ctime']}
    end
})

comments.remove_thread(50)
first_id = comments.insert(50,
    {'body' => 'First comment at top level','parent_id'=>-1,'ctime'=>1000}
)
second_id = comments.insert(50,
    {'body' => 'Second comment at top level','parent_id'=>-1,'ctime'=>1001}
)
id = comments.insert(50,
    {'body' => 'reply number one','parent_id'=>second_id,'ctime'=>1002}
)
id = comments.insert(50,
    {'body' => 'reply to reply','parent_id'=>id,'ctime'=>1003}
)
id = comments.insert(50,
    {'body' => 'reply number two','parent_id'=>second_id,'ctime'=>1002}
)
rendered_comments = comments.render_comments(50) {|c|
    puts ("  "*c['level']) + c['body']
}
