import {
  AuthTokenDetails,
  PostDetails,
  PostResponse,
  SocialProvider,
} from '@gitroom/nestjs-libraries/integrations/social/social.integrations.interface';
import { makeId } from '@gitroom/nestjs-libraries/services/make.is';
import dayjs from 'dayjs';
import {
  BadBody,
  RefreshToken,
  SocialAbstract,
} from '@gitroom/nestjs-libraries/integrations/social.abstract';
import { createHash, randomBytes } from 'crypto';
import FormDataNew from 'form-data';
import mime from 'mime-types';
import { Integration } from '@prisma/client';
import { hasExtension } from '@gitroom/helpers/utils/has.extension';

const VK_API_VERSION = '5.251';

export class VkProvider extends SocialAbstract implements SocialProvider {
  override maxConcurrentJob = 2; // VK has moderate API limits
  identifier = 'vk';
  name = 'VK';
  isBetweenSteps = false;
  scopes = [
    'vkid.personal_info',
    'email',
    'wall',
    'status',
    'docs',
    'photos',
    'video',
  ];

  editor = 'normal' as const;
  maxLength() {
    return 2048;
  }

  // VK answers with HTTP 200 even when a call fails: the failure is in the
  // payload (`{ error: { error_code, error_msg } }` for API methods). Without
  // this check a rejected wall.post would be stored as a published post with
  // an empty id.
  private vkResponse(json: any, message: string) {
    const error = json?.error;

    if (error) {
      const description =
        error?.error_msg || json?.error_description || String(error);

      // 5 - the user token is invalid, expired or was revoked in VK: the
      // channel has to be reconnected, retrying the same call never helps.
      if (error?.error_code === 5) {
        throw new RefreshToken(
          this.identifier,
          JSON.stringify(json),
          '{}',
          description
        );
      }

      throw new BadBody(
        this.identifier,
        JSON.stringify(json),
        '{}',
        `${message}: ${description}`
      );
    }

    if (!json?.response) {
      throw new BadBody(
        this.identifier,
        JSON.stringify(json ?? {}),
        '{}',
        message
      );
    }

    return json.response;
  }

  private redirectUri() {
    return `${
      process?.env.FRONTEND_URL?.indexOf('https') == -1
        ? `https://redirectmeto.com/${process?.env.FRONTEND_URL}`
        : `${process?.env.FRONTEND_URL}`
    }/integrations/social/vk`;
  }

  // The code exchange and the refresh return the same payload and are followed
  // by the same user_info lookup - only the grant in `formData` differs.
  private async requestToken(
    formData: FormData,
    device_id: string
  ): Promise<AuthTokenDetails> {
    formData.append('client_id', process.env.VK_ID!);

    // VK ID is OAuth 2.1 + PKCE, so the app's "Защищённый ключ" is not part of
    // the flow for most app types - it is sent only when it is configured, for
    // the confidential app types that do require it.
    if (process.env.VK_SECRET) {
      formData.append('client_secret', process.env.VK_SECRET);
    }

    const {
      access_token,
      refresh_token,
      expires_in,
      error,
      error_description,
    } = await (
      await this.fetch('https://id.vk.com/oauth2/auth', {
        method: 'POST',
        body: formData,
      })
    ).json();

    if (!access_token) {
      throw new RefreshToken(
        this.identifier,
        JSON.stringify({ error, error_description }),
        '{}',
        error_description || error || 'VK ID did not return an access token'
      );
    }

    const newFormData = new FormData();
    newFormData.append('client_id', process.env.VK_ID!);
    newFormData.append('access_token', access_token);

    const { user } = await (
      await this.fetch('https://id.vk.com/oauth2/user_info', {
        method: 'POST',
        body: newFormData,
      })
    ).json();

    if (!user?.user_id) {
      throw new BadBody(
        this.identifier,
        '{}',
        '{}',
        'VK ID did not return the profile of the connected user'
      );
    }

    const { user_id, first_name, last_name, avatar } = user;

    return {
      id: user_id,
      name: first_name + ' ' + last_name,
      accessToken: access_token,
      refreshToken: refresh_token + '&&&&' + device_id,
      expiresIn: dayjs().add(expires_in, 'seconds').unix() - dayjs().unix(),
      picture: avatar || '',
      username: first_name.toLowerCase(),
    };
  }

  async refreshToken(refresh: string): Promise<AuthTokenDetails> {
    const [oldRefreshToken, device_id] = refresh.split('&&&&');
    const formData = new FormData();
    formData.append('grant_type', 'refresh_token');
    formData.append('refresh_token', oldRefreshToken);
    formData.append('device_id', device_id);
    formData.append('state', makeId(32));
    formData.append('scope', this.scopes.join(' '));

    return this.requestToken(formData, device_id);
  }

  async generateAuthUrl() {
    const state = makeId(32);
    const codeVerifier = randomBytes(64).toString('base64url');
    const challenge = Buffer.from(
      createHash('sha256').update(codeVerifier).digest()
    )
      .toString('base64')
      .replace(/=*$/g, '')
      .replace(/\+/g, '-')
      .replace(/\//g, '_');

    return {
      url:
        'https://id.vk.com/authorize' +
        `?response_type=code` +
        `&client_id=${process.env.VK_ID}` +
        `&code_challenge_method=S256` +
        `&code_challenge=${challenge}` +
        `&redirect_uri=${encodeURIComponent(this.redirectUri())}` +
        `&state=${state}` +
        `&scope=${encodeURIComponent(this.scopes.join(' '))}`,
      codeVerifier,
      state,
    };
  }

  async authenticate(params: {
    code: string;
    codeVerifier: string;
    refresh?: string;
  }) {
    const [code, device_id] = params.code.split('&&&&');

    const formData = new FormData();
    formData.append('grant_type', 'authorization_code');
    formData.append('code_verifier', params.codeVerifier);
    formData.append('device_id', device_id);
    formData.append('code', code);
    formData.append('redirect_uri', this.redirectUri());

    return this.requestToken(formData, device_id);
  }

  private async uploadMedia(
    userId: string,
    accessToken: string,
    post: PostDetails
  ): Promise<{ id: string; type: string }[]> {
    return await Promise.all(
      (post?.media || []).map(async (media) => {
        const isVideo = hasExtension(media.path, 'mp4');

        const uploadServer = this.vkResponse(
          await (
            await this.fetch(
              isVideo
                ? `https://api.vk.com/method/video.save?access_token=${accessToken}&v=${VK_API_VERSION}`
                : `https://api.vk.com/method/photos.getWallUploadServer?owner_id=${userId}&access_token=${accessToken}&v=${VK_API_VERSION}`
            )
          ).json(),
          'VK refused to open an upload server for the media'
        );

        const slash = media.path.split('/').at(-1);

        // The media is streamed straight from its source (a local file when
        // STORAGE_PROVIDER=local) instead of being fetched back over the
        // public URL, which a self-hosted instance often cannot reach.
        // runStreamedUpload rebuilds the form per attempt - a consumed stream
        // can't be replayed.
        const value = await this.runStreamedUpload(async () => {
          const fileSize = await this.mediaSize(media.path, this.identifier);
          const stream = await this.mediaStream(media.path, this.identifier);

          const formData = new FormDataNew();
          formData.append(isVideo ? 'video_file' : 'photo', stream, {
            filename: slash,
            contentType: mime.lookup(slash!) || '',
            knownLength: fileSize,
          });

          return (
            await this.getSsrfSafeAxios().post(
              uploadServer.upload_url,
              formData,
              {
                headers: {
                  ...formData.getHeaders(),
                },
              }
            )
          ).data;
        }, this.identifier);

        if (isVideo) {
          return {
            id: uploadServer.video_id,
            type: 'video',
          };
        }

        const formSend = new FormData();
        formSend.append('photo', value.photo);
        formSend.append('server', value.server);
        formSend.append('hash', value.hash);

        const [{ id }] = this.vkResponse(
          await (
            await this.fetch(
              `https://api.vk.com/method/photos.saveWallPhoto?access_token=${accessToken}&v=${VK_API_VERSION}`,
              {
                method: 'POST',
                body: formSend,
              }
            )
          ).json(),
          'VK refused to save the uploaded photo'
        );

        return {
          id,
          type: 'photo',
        };
      })
    );
  }

  async post(
    userId: string,
    accessToken: string,
    postDetails: PostDetails[]
  ): Promise<PostResponse[]> {
    const [firstPost] = postDetails;

    // Upload media for the first post
    const mediaList = await this.uploadMedia(userId, accessToken, firstPost);

    const body = new FormData();
    body.append('message', firstPost.message);

    if (mediaList.length) {
      body.append(
        'attachments',
        mediaList.map((p) => `${p.type}${userId}_${p.id}`).join(',')
      );
    }

    const response = this.vkResponse(
      await (
        await this.fetch(
          `https://api.vk.com/method/wall.post?v=${VK_API_VERSION}&access_token=${accessToken}&client_id=${process.env.VK_ID}`,
          {
            method: 'POST',
            body,
          }
        )
      ).json(),
      'VK refused to publish the post'
    );

    return [
      {
        id: firstPost.id,
        postId: String(response.post_id),
        releaseURL: `https://vk.com/feed?w=wall${userId}_${response.post_id}`,
        status: 'completed',
      },
    ];
  }

  async comment(
    userId: string,
    postId: string,
    lastCommentId: string | undefined,
    accessToken: string,
    postDetails: PostDetails[],
    integration: Integration
  ): Promise<PostResponse[]> {
    const [commentPost] = postDetails;

    // Upload media for the comment
    const mediaList = await this.uploadMedia(userId, accessToken, commentPost);

    const body = new FormData();
    body.append('message', commentPost.message);
    body.append('post_id', postId);

    if (mediaList.length) {
      body.append(
        'attachments',
        mediaList.map((p) => `${p.type}${userId}_${p.id}`).join(',')
      );
    }

    const response = this.vkResponse(
      await (
        await this.fetch(
          `https://api.vk.com/method/wall.createComment?v=${VK_API_VERSION}&access_token=${accessToken}&client_id=${process.env.VK_ID}`,
          {
            method: 'POST',
            body,
          }
        )
      ).json(),
      'VK refused to publish the comment'
    );

    return [
      {
        id: commentPost.id,
        postId: String(response.comment_id),
        releaseURL: `https://vk.com/feed?w=wall${userId}_${postId}`,
        status: 'completed',
      },
    ];
  }
}
