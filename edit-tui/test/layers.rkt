#lang racket

;;; 新架构的边界检查：
;;;   - 插件只 require editor/api.rkt（和 feature api），不摸 engine / raw / host
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
  ;; 插件只能经 editor/api.rkt 接触 editor；feature api 是唯一额外入口。
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

;; 插件面不导出 plugin-state 写入口 / state constructor / resource 变更入口。
(check-false (regexp-match? #rx"state-set-plugin-state" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"state-plugin-states" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"make-app-state" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"resources-(add|remove|set-)" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"make-resource" api-src)
             "editor/api.rkt")

;; 插件面不整包导出 context / hooks / layout，避免 engine / registry / mouse 泄漏。
(check-false (regexp-match? #rx"\\(all-from-out \"context\\.rkt\\)" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"\\(all-from-out \"hooks\\.rkt\\)" api-src)
             "editor/api.rkt")
(check-false (regexp-match? #rx"\\(all-from-out \"layout\\.rkt\\)" api-src)
             "editor/api.rkt")

;; host-api 才导出渲染 / 尺寸同步。
(check-true (requires-any? "editor/host-api.rkt" #rx"panels-sync!")
            "editor/host-api.rkt")

;; host 走 host-api，不直接 require engine/store / ops/raw。
(check-true (requires-any? "edit.rkt" #rx"editor/host-api\\.rkt")
            "edit.rkt")
(check-false (requires-any? "edit.rkt" #rx"editor/(engine/store|ops/raw)")
             "edit.rkt")

;; app 是宿主装配层，也只经 host-api 接触 editor 内部。
(define app-files
  '("app/bootstrap.rkt"
    "app/layout.rkt"
    "app/actions.rkt"
    "app/frame.rkt"
    "app/event.rkt"))

(for ([f (in-list app-files)])
  (check-false (requires-any? f #rx"editor/(engine/store|ops/raw)") f)
  (check-false (requires-any? f #rx"plugins->command-table") f)
  (check-false (requires-any? f #rx"owned-command-table") f))

;; command 从 contribution registry 来；host 不再拼插件 command-table。
(check-false (requires-any? "edit.rkt" #rx"plugins->command-table")
             "edit.rkt")
(check-false (requires-any? "edit.rkt" #rx"owned-command-table")
             "edit.rkt")
(check-true (requires-any? "editor/plugin.rkt" #rx"point/command")
            "editor/plugin.rkt")

;;; ════════════════ 更细的边界 ════════════════

;; 插件不能直接摸 editor 内部模块（api.rkt 例外）。
(for ([f (in-list plugin-files)])
  (check-false
   (requires-any? f #rx"\\.\\./editor/(open|prompt|input|close|timer|job|layout|resource|mode|overlay|engine|ops|host-api|context|hooks|state)")
   f)
  (check-false (requires-any? f #rx"state-set-plugin-state") f)
  (check-false (regexp-match? #rx"editor-engine|edit-context-engine|change-context-engine"
                              (src f))
               f))

;; editor 不能 require host / plugins。
(define editor-files
  (for/list ([p (in-directory (build-path root "editor"))]
             #:when (regexp-match? #rx"\\.rkt$" (path->string p)))
    (path->string (find-relative-path root p))))

(for ([f (in-list editor-files)])
  (check-false (requires-any? f #rx"(^|/)(host|plugins)/") f)
  ;; editor 不做文件 IO / 不启线程 / 不碰 channel。
  (check-false (regexp-match? #rx"racket/file|display-to-file|file->string|async-channel|\\(thread\\b"
                              (src f))
               f))

;; 插件 API 不导出 host 编排函数。
(define api-src2 (src "editor/api.rkt"))
(check-false (regexp-match? #rx"run-plugin-" api-src2) "editor/api.rkt")
(check-false (regexp-match? #rx"plugins->" api-src2) "editor/api.rkt")

;; plugin.rkt 只做描述 / 聚合；执行器在 plugin-runtime.rkt。
(check-true (requires-any? "editor/plugin-runtime.rkt" #rx"context\\.rkt")
            "editor/plugin-runtime.rkt")
(check-true (requires-any? "editor/plugin-runtime.rkt" #rx"contributions\\.rkt")
            "editor/plugin-runtime.rkt")

;; features 是 app/chrome 内部层：只经 editor/api.rkt，不 require
;; editor/state.rkt / host / plugins / engine 实现。
(define (features-rkt-files dir)
  (append*
   (for/list ([p (in-directory dir)]
              #:when (regexp-match? #rx"\\.rkt$" (path->string p)))
     (list (path->string (find-relative-path root p))))))
(for ([f (in-list (features-rkt-files (build-path root "features")))])
  (check-false (requires-any? f #rx"(^|/)(host|plugins)/") f)
  (check-false (requires-any? f #rx"editor/(engine|ops|host-api|state)") f))

;; 具体 app 布局装配不在 editor/layout.rkt。
(check-false (requires-any? "editor/layout.rkt" #rx"make-editor-layout")
             "editor/layout.rkt")
(check-false (regexp-match? #rx"'docs" (src "editor/layout.rkt"))
             "editor/layout.rkt")

(displayln "edit-tui/test/layers.rkt: ok")
