// Stash HTTP Rewrite Script (request type)
// Intercepts http://fraud-check.stash/ requests,
// uses $httpClient with X-Stash-Selected-Proxy to fetch ippure.com,
// and returns the result as a synthetic response.

const url = $request.url || "";
console.log("Request URL: " + url);
const match = url.match(/[?&]node=([^&]+)/);
const node = match ? decodeURIComponent(match[1]) : "";
console.log("Node: " + node);

if (!node) {
  $done({
    response: {
      status: 400,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error: "missing node parameter" }),
    },
  });
} else {
  $httpClient.get(
    {
      url: "https://my.ippure.com/v1/info",
      timeout: 15,
      headers: {
        "X-Stash-Selected-Proxy": encodeURIComponent(node),
      },
    },
    (error, response, data) => {
      console.log("Response status: " + (response ? response.status || response.statusCode : "null"));
      if (error) {
        console.log("Error: " + error);
        $done({
          response: {
            status: 502,
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ error: error.toString(), node: node }),
          },
        });
        return;
      }
      $done({
        response: {
          status: response.status || response.statusCode || 200,
          headers: { "Content-Type": "application/json" },
          body: data,
        },
      });
    }
  );
}
