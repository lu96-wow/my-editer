#lang racket

;;; 新架构的边界检查：
;;;   - 插件只 require editor/api.rkt，不摸 engine / raw / host
;;;   - raw 是唯一 require engine/api 的操作模块
;;;   - 插件面不导出 engine 生命周期 / engine-apply-view-action!

(require rackunit
         racket/file
         racket/path
         racket/string)

(define test-dir (path->complete-path (find-system-path 'run-file)))
(define root (simplify-path (build-path (path-only test-dir) 'up)))

(define (src rel)
  (file->string (build-path root rel)))

(define (requires-any? rel pattern)
  (regexp-match? pattern (src rel)))

;; 纯语言库 / 纯 face 值可以复用；旧 editor / boot / host 不行。

(define plugin-files
  '("plugins/pair/plugin.rkt"
    "plugins/indent/plugin.rkt"
    "plugins/racket-color/plugin.rkt"
    "plugins/layout/plugin.rkt"
    "plugins/filetree/plugin.rkt"
    "plugins/resources/plugin.rkt"
    "plugins/completion/plugin.rkt"
    "plugins/docs/plugin.rkt"))

(for ([f (in-list plugin-files)])
  ;; 插件只能经 editor/api.rkt 接触 editor。
  (check-true (regexp-match? #rx"editor/api\\.rkt" (src f)) f)
  (check-false (requires-any? f #rx"\\.\\./editor/(engine|ops|host-api|context|hooks|state)") f)
  ;; 允许纯语言库 / face；不允许旧 edit-tui 的 editor / boot / host。
  (check-false
   (requires-any? f #rx"\\.\\./\\.\\./edit-tui/(app|boot|host|render|edit|filetree|chrome|resources|core/(base|command|engine|focus|layout|panel|projection|resource))")
   f)
  (check-false (requires-any? f #rx"/host/") f))

;; raw 是唯一直接调用 engine 操作面的 ops 模块。
(check-true (requires-any? "editor/ops/raw.rkt" #rx"engine/api\\.rkt")
            "editor/ops/raw.rkt")
(check-true (requires-any? "editor/ops/raw.rkt" #rx"engine-apply-view-action!")
            "editor/ops/raw.rkt")

;; surface 不直接 require engine/store；它只经 engine/api 做查询。
(check-false (requires-any? "editor/ops/surface.rkt" #rx"engine/store\\.rkt")
             "editor/ops/surface.rkt")

;; 插件面不导出 engine 生命周期 / engine-apply-view-action!。
(define api-src (src "editor/api.rkt"))
(check-false (regexp-match? #rx"make-engine" api-src) "editor/api.rkt")
(check-false (regexp-match? #rx"engine-create-" api-src) "editor/api.rkt")
(check-false (regexp-match? #rx"engine-apply-view-action!" api-src) "editor/api.rkt")
(check-false (regexp-match? #rx"render-display-patch" api-src) "editor/api.rkt")
(check-false (regexp-match? #rx"panels-sync!" api-src) "editor/api.rkt")

;; host-api 才导出渲染 / 尺寸同步。
(check-true (requires-any? "editor/host-api.rkt" #rx"panels-sync!")
            "editor/host-api.rkt")

;; host 走 host-api，不直接 require engine/store / ops/raw。
(check-true (requires-any? "host/final.rkt" #rx"editor/host-api\\.rkt")
            "host/final.rkt")
(check-false (requires-any? "host/final.rkt" #rx"editor/(engine/store|ops/raw)")
             "host/final.rkt")

(displayln "edit-tui-rebuild/test/layers.rkt: ok")
