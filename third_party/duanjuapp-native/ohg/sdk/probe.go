package sdk

// 本文件只放供诊断与契约测试使用的只读方法。生产链路不调用它们，
// 但它们复用与 ResolvePlayback 完全相同的注册设备、签名和请求路径，
// 便于在服务端的播放模型结构变化时拿到未经解析的原始响应。

import (
	"context"
	"fmt"

	"duanjuapp/native/ohg/internal/protocol"
	"duanjuapp/native/ohg/internal/protocol/sign"
)

// RawPlayback 返回一集播放模型的原始响应体。
//
// 与 ResolvePlayback 的差别仅在于不做解析：调用方可以检查服务端新加的
// 字段（例如新的加密标记或密钥下发位置）。仅供诊断/契约测试，返回体里
// 含有 CDN 地址与包装密钥材料，不要写日志或外传。
func (c *Client) RawPlayback(ctx context.Context, episodeID string) ([]byte, error) {
	return withFreshDevice(ctx, c, true, func(ctx context.Context) ([]byte, error) {
		if !validID(episodeID) {
			return nil, fmt.Errorf("invalid episode ID")
		}
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		body, err := protocol.PlaybackBody(episodeID)
		if err != nil {
			return nil, err
		}
		ticket := c.clock().UnixMilli()
		// Diagnostics must sign playback exactly like production, otherwise the
		// probe itself would observe the empty 200 body this fix removes.
		rawQuery, headers := sign.SignPlaybackPOST(protocol.PathPlayback, protocol.DeviceQueryPairs(c.identity(p)), ticket, p.DeviceID, protocol.VersionName, body, nil)
		raw, _, err := c.doRaw(ctx, "POST", c.apiOrigin+protocol.PathPlayback+"?"+rawQuery, anonymousHeaders(c, p, ticket, headers), body)
		return raw, err
	})
}
