#!/bin/bash
## Requirementsk jq, curl

#SCRIPT_DIR=$(cd $(dirname $0); pwd)
#echo $SCRIPT_DIR

curl -X POST 'https://api.notion.com/v1/databases/8d1543d8588a4703a3cf4ca55338c670/query' \
  -H 'Authorization: Bearer '"$NOTION_API_KEY"'' \
  -H 'Notion-Version: 2022-06-28' \
  -H "Content-Type: application/json" \
  --data '{
  "filter" : {
  "and": [
  { "property": "Status", "status": {"does_not_equal": "Done"}},
  { "property": "Status", "status": {"does_not_equal": "Failure"}}
  ]}}' | \
jq "
  [
    .results[] |

    {
      obj: .,
      start_date: (
        try (
          .properties.\"Planned/End Date\".date.start |
            strptime(\"%Y-%m-%dT%H:%M:%S.000%z\") |
            mktime) catch null
        ),
      end_date: (
        try (
          .properties.\"Planned/End Date\".date.end |
            strptime(\"%Y-%m-%dT%H:%M:%S.000%z\") |
            mktime) catch null
        ),
    } |

    {
      url: .obj.url,
      title: .obj.properties.Name.title[].plain_text,
      due_date: .obj.properties.\"Planned/End Date\".date,
      progress: (try (100 - (now - .start_date)/(.end_date - .start_date)*100) catch false)
    }
  ]
"
