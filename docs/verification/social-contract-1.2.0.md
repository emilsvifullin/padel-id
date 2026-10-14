# Social 1.2.0 contract (local implementation)

All RPCs require a live authenticated session and active player. Table access is revoked; RPCs alone authorize every read/write. No remote DB changes are authorized here.

Routes map to following RPCs. UUID resource IDs; numeric message IDs. `p` is JSON body/query. Create/send/comment/report require `Idempotency-Key` UUID, passed as `p_client_id` (or added to `p.client_id` for create_conversation/create_post).

| Route | RPC arguments |
|---|---|
| GET /v1/social/settings | social_settings() |
| PATCH /v1/social/settings | update_social_settings(p) where {messages_from: friends/everyone/nobody, notify_messages: bool, notify_activity: bool} |
| GET /v1/social/blocks | blocked_players() |
| PUT /v1/social/blocks/:id | block_player(p_player uuid) |
| DELETE /v1/social/blocks/:id | unblock_player(p_player uuid) |
| PUT /v1/social/follows/:id | follow_player(p_player uuid) |
| DELETE /v1/social/follows/:id | unfollow_player(p_player uuid) |
| GET /v1/social/follows | following_players() |
| POST /v1/social/reports | report_content(p jsonb,p_client_id uuid), {target_type: player/message/post/comment, target_id: string, reason: spam/harassment/inappropriate/other, detail?: string<=500} |
| GET /v1/conversations | conversations(p), {limit:1..50,offset:0..1000} |
| POST /v1/conversations | create_conversation(p), {client_id: uuid,kind:direct/group/game,title?:2..80,description?:<=500,visibility?:public/private,player_ids?:uuid[]<=30,player_id?:uuid,game_id?:uuid,city_id?:int,club_id?:int} |
| GET /v1/conversations/:id | conversation(p_conversation uuid) |
| POST /v1/conversations/:id/members | conversation_member_action(p_conversation uuid,p_player uuid,p_action text), action=add/remove/transfer_owner; self join/leave handled below |
| POST /v1/conversations/:id/join | conversation_member_action(p_conversation uuid,p_player null,p_action join) |
| POST /v1/conversations/:id/leave | conversation_member_action(p_conversation uuid,p_player null,p_action leave) |
| GET /v1/conversations/:id/messages | conversation_messages(p_conversation uuid,p), {limit:1..50,before_id?:int64,after_id?:int64} |
| POST /v1/conversations/:id/messages | send_message(p_conversation uuid,p_body text,p_client_id uuid) body {body:string 1..4000} |
| POST /v1/conversations/:id/read | mark_conversation_read(p_conversation uuid,p_message bigint), body {message_id:int64} |
| GET /v1/social/groups | social_groups(p), {query?:<=80,city_id?:int,limit,offset} |
| GET /v1/social/feed | social_feed(p), {scope?:all/following,mine?:bool,group_id?:uuid,limit,offset} |
| POST /v1/social/posts | create_post(p), {client_id:uuid,body:1..4000,visibility?:public/friends,group_id?:uuid,club_id?:int} |
| GET /v1/social/posts/:id | social_post(p_post uuid) |
| DELETE /v1/social/posts/:id | delete_post(p_post uuid) |
| GET /v1/social/posts/:id/comments | post_comments(p_post uuid,p), {limit,offset} |
| POST /v1/social/posts/:id/comments | comment_on_post(p_post uuid,p_body text,p_client_id uuid), {body:1..1000} |
| DELETE /v1/social/comments/:id | delete_comment(p_comment uuid) |
| PUT /v1/social/posts/:id/reaction | react_to_post(p_post uuid,p_reaction text), {reaction:like/celebrate/support/null} |
| GET /v1/notifications | social_notifications(p), {limit,offset} |
| POST /v1/notifications/read | read_social_notifications(p_id uuid default null), {id?:uuid}, absent marks all |
| GET /v1/admin/reports | moderation_reports(p), {limit,offset} |
| POST /v1/admin/reports/:id | moderate_report(p_report uuid,p_decision text), {decision:dismiss/hide} |

All collections `{items:[],next_offset:int|null}`. Conversation `{id,kind,title,description,visibility,game_id,city_id,club_id,owner_id,created_at,updated_at,members:[{player:PlayerCard,role:owner/member}],unread_count:int,latest_message:Message|null}`. DM title shows peer name; games title `Чат игры`. Public groups reuse group conversations, not a separate membership/user system. DM friends-only by default; recipient setting allows everyone/nobody. Group add requires owner+accepted friendship; public group self-join supported. Game chat reads/send require current accepted game lineup. Owner can transfer ownership to an existing active member, then leave. Transfer replay to the current owner is a membership-checked no-op; a member cannot assign a new owner. Removing/leaving the current owner is refused.

Message `{id:int64,conversation_id:uuid,sender:PlayerCard,body:string,created_at,client_id:uuid,deleted:bool}`; messages page `{items:[],next_before:int64|null,latest_id:int64|null}` ascending chronological within page; after_id polls only newer messages. No direct DB realtime channel, so client polls while visible/reconnects via gateway. Read high-water mark bounded to an actual message in same chat.

Post `{id,author:PlayerCard,body,visibility,group_id,club_id,created_at,reaction_count:int,comment_count:int,my_reaction:string|null}`. Comment `{id,post_id,author:PlayerCard,body,created_at}`. Notifications `{id,kind,title,resource_id:uuid|null,created_at,read_at}` generic titles keep personal message content out of inbox/lockscreen. Reports `{id,target_type,target_id,reason,detail,status,created_at}` admins only.

Errors: existing invalid_request/forbidden/not_found/rate_limited/player_not_found/idempotency_key_required/version_conflict/not_authenticated/session_expired, plus social_blocked (403), messages_not_allowed (403), conversation_not_found (404), conversation_owner_required (403), conversation_owner_cannot_leave (409), post_not_found (404), report_not_found (404). Hide inaccessible objects as not_found variants. Successful action returns current resource; block/follow/settings etc return settings/list/status; deletion/read returns {ok:true}.

Bilateral blocks prevent visibility, follows/friend requests, feed/comment exposure and DM/send; erase current friendships/follows. Existing scored history retains sports facts but masks personal cards via visible_card. Avatar access requires a bearer token and the same visible-player gate; the gateway no longer permits anonymous cached image access.

Groups page items are compact `{id,title,description,visibility,city_id,club_id,owner_id,member_count,joined}`; opening or joining returns Conversation. Blocks/follows page items are PlayerCard directly. PlayerProfile adds top-level `is_following`, `followers_count`, `following_count`. Report create returns `{id,status}`; admin report rows additionally include reporter_id,reviewed_by,reviewed_at (only moderator).

`conversation_messages` hides bilateral blocked senders; deleted/moderated messages return `deleted:true` and generic removed body. Clients must periodically refresh currently visible message windows (incremental after_id alone cannot detect removal), discard locally cached private content after block/leave/deletion/sign-out, and clear avatar caches on account/privacy change. Inbox includes generic friend/game lifecycle notifications alongside messages/comments.
