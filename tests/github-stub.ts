// A stand-in for the GitHub API and release downloads that `mica-tools release attach` reads and
// writes, for tests/publish-test.sh. Its state is a directory the test arranges between runs:
//
//   <state>/releases/<tag>/                a published release of micaoss/<repository>
//   <state>/releases/<tag>/body            its notes
//   <state>/releases/<tag>/assets/<name>   an asset
//   <state>/releases/<tag>/unreadable      its assets do not download
//   <state>/tags/<tag>                     the commit the tag names
//   <state>/tags/<tag>.status              the HTTP status its lookup answers instead
//   <state>/log                            one "<METHOD> <path>" line per request
//   <state>/port                           written once the server listens
//
//   bun tests/github-stub.ts <state>
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const state = process.argv[2]
if (!state) throw new Error('usage: bun tests/github-stub.ts <state>')
const releases = join(state, 'releases')

const tags = (): string[] => (existsSync(releases) ? readdirSync(releases).sort() : [])
const idOf = (tag: string): number => tags().indexOf(tag) + 1
const tagOf = (id: number): string | undefined => tags()[id - 1]

function shape(base: string, repository: string, tag: string): unknown {
  const dir = join(releases, tag)
  const assets = existsSync(join(dir, 'assets')) ? readdirSync(join(dir, 'assets')).sort() : []
  return {
    id: idOf(tag), tag_name: tag, draft: false, prerelease: false,
    body: existsSync(join(dir, 'body')) ? readFileSync(join(dir, 'body'), 'utf8') : '',
    assets: assets.map((name, i) => ({ id: idOf(tag) * 1000 + i, name, url: `${base}/download/${repository}/${tag}/${name}` })),
  }
}

const server = Bun.serve({
  port: 0,
  async fetch(request) {
    const url = new URL(request.url), path = url.pathname, base = `http://127.0.0.1:${server.port}`
    appendFileSync(join(state, 'log'), `${request.method} ${path}${url.search}\n`)
    let m = /^\/repos\/micaoss\/[^/]+\/git\/ref\/tags\/(.+)$/.exec(path)
    if (m && request.method === 'GET') {
      const file = join(state, 'tags', m[1]!)
      if (existsSync(`${file}.status`)) return new Response('{}', { status: Number(readFileSync(`${file}.status`, 'utf8')) })
      if (!existsSync(file)) return new Response('{}', { status: 404 })
      return Response.json({ ref: `refs/tags/${m[1]}`, object: { type: 'commit', sha: readFileSync(file, 'utf8').trim() } })
    }
    m = /^\/repos\/micaoss\/([^/]+)\/releases$/.exec(path)
    if (m && request.method === 'GET') {
      const page = Number(url.searchParams.get('page') ?? '1')
      return Response.json(page === 1 ? tags().map(t => shape(base, m![1]!, t)) : [])
    }
    m = /^\/repos\/micaoss\/([^/]+)\/releases\/tags\/(.+)$/.exec(path)
    if (m && request.method === 'GET')
      return existsSync(join(releases, m[2]!)) ? Response.json(shape(base, m[1]!, m[2]!)) : new Response('{}', { status: 404 })
    m = /^\/repos\/micaoss\/([^/]+)\/releases\/(\d+)$/.exec(path)
    if (m && request.method === 'PATCH') {
      const tag = tagOf(Number(m[2]))
      if (tag === undefined) return new Response('{}', { status: 404 })
      writeFileSync(join(releases, tag, 'body'), (await request.json() as { body: string }).body)
      return Response.json(shape(base, m[1]!, tag))
    }
    m = /^\/repos\/micaoss\/([^/]+)\/releases\/(\d+)\/assets$/.exec(path)
    if (m && request.method === 'POST') {
      const tag = tagOf(Number(m[2])), name = url.searchParams.get('name') ?? ''
      if (tag === undefined) return new Response('{}', { status: 404 })
      const file = join(releases, tag, 'assets', name)
      if (existsSync(file)) return new Response('{}', { status: 422 })
      mkdirSync(join(releases, tag, 'assets'), { recursive: true })
      writeFileSync(file, new Uint8Array(await request.arrayBuffer()))
      return new Response('{}', { status: 201 })
    }
    m = /^\/download\/[^/]+\/([^/]+)\/([^/]+)$/.exec(path)
    if (m && request.method === 'GET') {
      const file = join(releases, m[1]!, 'assets', m[2]!)
      if (existsSync(join(releases, m[1]!, 'unreadable')) || !existsSync(file)) return new Response('', { status: 404 })
      return new Response(readFileSync(file))
    }
    return new Response('{}', { status: 404 })
  },
})
writeFileSync(join(state, 'port'), `${server.port}\n`)
