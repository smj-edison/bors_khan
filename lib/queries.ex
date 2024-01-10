defmodule Queries do
  @valid_chars ~c"0123456789abcdefghijklmnopqrstuvwxyz"

  defp hex_list(list, 0) do
    list
  end

  defp hex_list(list, left) do
    hex_list([Enum.random(@valid_chars) | list], left - 1)
  end

  defp hex_string(count) do
    to_string(hex_list([], count))
  end

  def gen_fkey() do
    version = "1.0"
    random = hex_string(67)
    time = to_string(System.os_time(:millisecond))

    version <> "_" <> random <> "_" <> time
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
    {:ok, query} = File.read("text/login.txt")

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
          "query" => query,
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
    {:ok, query} = File.read("text/get_program.txt")

    %{:status => 200, :body => body} =
      Req.post!(build_req(cookies, "programQuery"),
        json: %{
          "operationName" => "programQuery",
          "query" => query,
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
      "originScratchpad" => spun_off_of
    } = body["data"]["programById"]

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
    {:ok, query} = File.read("text/create_program.txt")
    {:ok, empty_image} = File.read("text/empty_image.txt")

    %{:status => 200, :body => body} =
      Req.post!(build_req(cookies, "createProgram"),
        json: %{
          "operationName" => "createProgram",
          "query" => query,
          "variables" => %{
            "title" => title,
            "userAuthoredContentType" => type,
            "curationNodeSlug" => "computer-programming",
            "revision" => %{
              "code" => code,
              "configVersion" => 4,
              "folds" => [],
              "imageUrl" => empty_image
            }
          }
        }
      )

    body["data"]["createProgram"]["program"]["id"]
  end

  def update_program!(cookies, program_id, title, code) do
    {:ok, query} = File.read("text/update_program.txt")
    {:ok, empty_image} = File.read("text/empty_image.txt")

    %{:status => 200} =
      Req.post!(build_req(cookies, "updateProgram"),
        json: %{
          "operationName" => "updateProgram",
          "query" => query,
          "variables" => %{
            "programId" => program_id,
            "title" => title,
            "revision" => %{
              "code" => code,
              "configVersion" => 4,
              "folds" => [],
              "imageUrl" => empty_image
            }
          }
        }
      )

    :ok
  end

  def delete_program!(cookies, program_id) do
    {:ok, query} = File.read("text/delete_program.txt")

    %{status: 200} =
      Req.post!(build_req(cookies, "deleteProgram"),
        json: %{
          "operationName" => "deleteProgram",
          "query" => query,
          "variables" => %{
            "programID" => program_id
          }
        }
      )

    :ok
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

  def get_program_comments!(cookies, program_id, sort_order, cursor = nil) do
    {:ok, query} = File.read("text/get_program_comments.txt")

    variables = %{
      "topicId" => program_id,
      "focusKind" => "scratchpad",
      "feedbackType" => "COMMENT",
      "currentSort" => sort_order_to_number(sort_order)
    }

    if cursor != nil do
      variables = Map.put(variables, "cursor", cursor)
    end

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "feedbackQuery"),
        json: %{
          "operationName" => "feedbackQuery",
          "query" => query,
          "variables" => variables
        }
      )

    %{"cursor" => cursor, "feedback" => feedback} = body["data"]["feedback"]

    %{
      cursor: cursor,
      feedback: compact_feedback(feedback)
    }
  end

  def get_comments_on_comment!(cookies, comment_key, cursor = nil, limit = 100) do
    {:ok, query} = File.read("text/get_comments_on_comment.txt")

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "getFeedbackRepliesPage"),
        json: %{
          "operationName" => "getFeedbackRepliesPage",
          "query" => query,
          "variables" => %{
            "limit" => limit,
            "postKey" => comment_key
          }
        }
      )
  end

  def comment_on_program!(cookies, program_id, content) do
    {:ok, query} = File.read("text/comment_on_program.txt")

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "AddFeedbackToDiscussion"),
        json: %{
          "operationName" => "AddFeedbackToDiscussion",
          "query" => query,
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

    %{key: feedback["key"], expandKey: feedback["expandKey"]}
  end

  def comment_on_comment!(cookies, comment_key, content) do
    {:ok, query} = File.read("text/comment_on_comment.txt")

    %{status: 200, body: body} =
      Req.post!(build_req(cookies, "AddFeedbackToDiscussion"),
        json: %{
          "operationName" => "AddFeedbackToDiscussion",
          "query" => query,
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

    %{key: feedback["key"], expandKey: feedback["expandKey"]}
  end
end
