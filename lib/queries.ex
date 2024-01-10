defmodule Queries do
  @valid_chars ~c"0123456789abcdefghijklmnopqrstuvwxyz"

  defp rand_list(list, 0) do
    list
  end

  defp rand_list(list, left) do
    rand_list([Enum.random(@valid_chars) | list], left - 1)
  end

  defp rand_string(count) do
    to_string(rand_list([], count))
  end

  def get_text!(name) do
    {:ok, query} = File.read([:code.priv_dir(:bors_khan), name <> ".txt"] |> Path.join())

    query
  end

  def gen_fkey() do
    version = "1.0"
    random = rand_string(67)
    time = to_string(System.os_time(:millisecond))

    version <> "_" <> random <> "_" <> time
  end

  def sort_order_to_number(sort_order) do
    case sort_order do
      :recent ->
        2

      :trending ->
        5

      :votes ->
        1

      _ ->
        sort_order_to_number(:recent)
    end
  end

  def compact_feedback(feedback) do
    Enum.map(feedback, fn comment ->
      %{
        kaid: comment["author"]["kaid"],
        nickname: comment["author"]["nickname"],
        content: comment["content"],
        flags: comment["flags"],
        key: comment["key"],
        expand_key: comment["expandKey"]
      }
    end)
  end

  def compact_notifs!(notifs) do
    Enum.map(notifs, fn notif ->
      case notif["__typename"] do
        "ModeratorNotification" ->
          %{
            type: :moderator,
            content: notif["text"],
            brand_new: notif["brandNew"]
          }

        "ProgramFeedbackNotification" ->
          %{
            type: :program_comment,
            content: notif["content"],
            brand_new: notif["brandNew"],
            expand_key: notif["urlsafeKey"]
          }

        "ResponseFeedbackNotification" ->
          %{
            type: :comment_on_comment,
            content: notif["content"],
            brand_new: notif["brandNew"],
            expand_key: notif["urlsafeKey"]
          }

        _ ->
          %{
            type: :unknown
          }
      end
    end)
  end

  def cookies_to_map(cookies) do
    Enum.reduce(cookies, %{}, fn cookie, map ->
      cookie = List.first(String.split(cookie, ";"))
      [key, value] = String.split(cookie, "=")

      Map.merge(%{key => value}, map)
    end)
  end

  def cookies_to_str(cookie_map) do
    cookie_map
    |> Enum.map(fn {key, value} -> key <> "=" <> value end)
    |> Enum.join("; ")
  end

  def login!(username, password) do
    fkey = gen_fkey()

    # get session cookies
    %{status: 200, headers: headers} = Req.get!("https://khanacademy.org/login")
    cookies = cookies_to_map(headers["set-cookie"])
    cookies = Map.merge(cookies, %{"fkey" => fkey})

    %{status: 200, headers: headers, body: body} =
      Req.post!(
        build_req(cookies, "loginWithPasswordMutation"),
        json: %{
          "operationName" => "loginWithPasswordMutation",
          "query" => get_text!("login"),
          "variables" => %{
            "identifier" => username,
            "password" => password
          }
        }
      )

    cookies = Map.merge(cookies, cookies_to_map(headers["set-cookie"]))

    %{cookies: cookies, kaid: body["data"]["loginWithPassword"]["user"]["kaid"]}
  end

  def build_req(cookies, url) do
    Req.new(
      base_url: "https://www.khanacademy.org/api/internal/graphql/" <> url,
      headers: %{
        "x-ka-fkey": cookies["fkey"],
        cookie: cookies_to_str(cookies)
      }
    )
  end

  @doc """
  Gets a program given a program id.
  """
  def get_program!(cookies, program_id) do
    %{:status => 200, :body => body} =
      Req.post!(build_req(cookies, "programQuery"),
        json: %{
          "operationName" => "programQuery",
          "query" => get_text!("get_program"),
          "variables" => %{
            programId: program_id
          }
        }
      )

    %{
      "title" => title,
      "id" => id,
      "revision" => %{"code" => code, "editorType" => type},
      "creatorProfile" => %{"kaid" => kaid, "nickname" => nickname},
      "width" => width,
      "height" => height,
      "originScratchpad" => origin_scratchpad
    } = body["data"]["programById"]

    spun_off_of =
      if origin_scratchpad != nil do
        List.last(String.split(origin_scratchpad["url"], "/"))
      else
        nil
      end

    %{
      title: title,
      id: id,
      code: code,
      type: type,
      kaid: kaid,
      nickname: nickname,
      width: width,
      height: height,
      spun_off_of: spun_off_of
    }
  end

  def create_program!(cookies, title, type, code) do
    # TODO: check title for inappropriateness here

    %{:status => 200, :body => body} =
      Req.post!(build_req(cookies, "createProgram"),
        json: %{
          "operationName" => "createProgram",
          "query" => get_text!("create_program"),
          "variables" => %{
            "title" => title,
            "userAuthoredContentType" => type,
            "curationNodeSlug" => "computer-programming",
            "revision" => %{
              "code" => code,
              "configVersion" => 4,
              "folds" => [],
              "imageUrl" => get_text!("empty_image")
            }
          }
        }
      )

    body["data"]["createProgram"]["program"]["id"]
  end

  def update_program!(cookies, program_id, title, code) do
    # TODO: check title for inappropriateness here

    %{:status => 200} =
      Req.post!(build_req(cookies, "updateProgram"),
        json: %{
          "operationName" => "updateProgram",
          "query" => get_text!("update_program"),
          "variables" => %{
            "programId" => program_id,
            "title" => title,
            "revision" => %{
              "code" => code,
              "configVersion" => 4,
              "folds" => [],
              "imageUrl" => get_text!("empty_image")
            }
          }
        }
      )

    :ok
  end

  def delete_program!(cookies, program_id) do
    %{status: 200} =
      Req.post!(build_req(cookies, "deleteProgram"),
        json: %{
          "operationName" => "deleteProgram",
          "query" => get_text!("delete_program"),
          "variables" => %{
            "programID" => program_id
          }
        }
      )

    :ok
  end

  def get_program_comments!(cookies, program_id, sort_order, cursor) do
    variables = %{
      "topicId" => program_id,
      "focusKind" => "scratchpad",
      "feedbackType" => "COMMENT",
      "currentSort" => sort_order_to_number(sort_order)
    }

    variables =
      if cursor != nil do
        Map.put(variables, "cursor", cursor)
      else
        variables
      end

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "feedbackQuery"),
        json: %{
          "operationName" => "feedbackQuery",
          "query" => get_text!("get_program_comments"),
          "variables" => variables
        }
      )

    %{"cursor" => cursor, "feedback" => feedback} = body["data"]["feedback"]

    %{
      cursor: cursor,
      feedback: compact_feedback(feedback)
    }
  end

  def get_comments_on_comment!(cookies, comment_key, cursor, limit) do
    variables = %{
      "limit" => limit,
      "postKey" => comment_key
    }

    variables =
      if cursor != nil do
        Map.put(variables, "cursor", cursor)
      else
        variables
      end

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "getFeedbackRepliesPage"),
        json: %{
          "operationName" => "getFeedbackRepliesPage",
          "query" => get_text!("get_comments_on_comment"),
          "variables" => variables
        }
      )

    %{"cursor" => cursor, "feedback" => feedback} = body["data"]["feedbackRepliesPaginated"]

    %{
      cursor: cursor,
      feedback: compact_feedback(feedback)
    }
  end

  def comment_on_program!(cookies, program_id, content) do
    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "AddFeedbackToDiscussion"),
        json: %{
          "operationName" => "AddFeedbackToDiscussion",
          "query" => get_text!("comment_on_program"),
          "variables" => %{
            "feedbackType" => "COMMENT",
            "focusId" => program_id,
            "focusKind" => "scratchpad",
            "shownLowQualityNotice" => false,
            "textContent" => content
          }
        }
      )

    feedback = body["data"]["addFeedbackToDiscussion"]["feedback"]

    %{key: feedback["key"], expand_key: feedback["expandKey"]}
  end

  def comment_on_comment!(cookies, comment_key, content) do
    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "AddFeedbackToDiscussion"),
        json: %{
          "operationName" => "AddFeedbackToDiscussion",
          "query" => get_text!("comment_on_comment"),
          "variables" => %{
            "feedbackType" => "REPLY",
            "fromVideoAuthor" => false,
            "parentKey" => comment_key,
            "shownLowQualityNotice" => false,
            "textContent" => content
          }
        }
      )

    feedback = body["data"]["addFeedbackToDiscussion"]["feedback"]

    %{key: feedback["key"], expand_key: feedback["expandKey"]}
  end

  def get_notifications!(cookies, cursor) do
    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "getNotificationsForUser"),
        json: %{
          "operationName" => "getNotificationsForUser",
          "query" => get_text!("get_notifications"),
          "variables" => %{
            "after" => cursor
          }
        }
      )

    %{
      "pageInfo" => %{"nextCursor" => next_cursor},
      "notifications" => notifs
    } = body["data"]["user"]["notifications"]
  end
end
