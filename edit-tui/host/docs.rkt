#lang racket

;;; edit-tui-rebuild/host/docs.rkt —— docs 跨插件请求的 host 解释
;;;
;;; completion 只发 show-docs-action；这里拿到 docs owner 的 ps，调用
;;; docs 自己的更新函数，再按 owner 写回。host 不替插件实现 docs 逻辑。

(require "../editor/host-api.rkt"
         "../plugins/docs/api.rkt")

(provide editor-show-docs!)

(define (editor-show-docs! ed state name)
  (define ps (state-plugin-state state 'docs))
  (define-values (state* ps* actions) (docs-show-name! ed state ps name))
  (values (state-set-plugin-state state* 'docs ps*) actions))
