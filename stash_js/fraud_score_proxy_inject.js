// Stash HTTP Rewrite Script (request type)
// Intercepts http://fraud-check.local/ requests,
// uses $httpClient with X-Stash-Selected-Proxy to fetch ippure.com,
// and returns the result as a synthetic response.

const url = $request.url || "";
const match = url.match(/[?&]node=([^&]+)/);
const node = match ? decodeURIComponent(match[1]) : "";

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
      if (error) {
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
