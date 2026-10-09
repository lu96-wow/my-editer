#lang racket

;;; lab-re-rebuild/builtin/highlight.rkt —— 属性插件（font-lock 类）包。
;;;
;;; 用 **版本槽** 管每版本的插件增量状态（替代旧的 token/影子/结果外部表）：
;;;   · `define-document-slot hl`：值 = hl-state（path + 适用插件集 + 各插件 state/fills）
;;;   · fork 时由 transform 增量推进（新版本新 hash，旧版本不动）→ undo 天然带状态
;;;   · before-render：槽未初始化则整篇 open；然后把 fills 经 e-attr-face! 写回 face 端口
;;;   · document-closed：不用清理（槽随版本可达性回收）
;;;
;;; 传输：现在同步算（transform + before-render）；换 place 时只需把 state 序列化出去，
;;; 版本关联交给槽（结果落到该版本的槽）。
;;; 写回是 effect e-attr-face!（O(1)，不进 history）。路径元数据走 document-api。

(require "../kernel/api.rkt"
         "../config/plugins.rkt"
         "document-api.rkt"
         "highlight/api.rkt"
         "highlight/registry.rkt")

(provide register-highlight!)

;;; ================= 版本槽 =================

(struct hl-state (path plugins states) #:transparent)
;; path    : string               该文档路径（插件 applies?/change 用）
;; plugins : (listof plugin)      适用插件集（open 时定，版本间不变）
;; states  : hash name -> (cons state fills)

;; fork：把上一版本的插件状态增量推进到新版本（新建 hash，旧版本不动）。
(define (hl-transform old ctx)
  (cond
    [(not old) #f]
    [else
     (define edits (fork-ctx->edits ctx))
     (define lines (list->vector (track->list (fork-ctx-new-text ctx))))
     (define path (hl-state-path old))
     (define ps (hl-state-plugins old))
     (define st0 (hl-state-states old))
     (define st (make-hash))
     (for ([p (in-list ps)])
       (define o (hash-ref st0 (plugin-name p)))
       (define-values (s fl) ((plugin-change p) (car o) edits lines path))
       (hash-set! st (plugin-name p) (cons s fl)))
     (hl-state path ps st)]))

(define-document-slot hl #:default #f #:fork (transform hl-transform))

;;; ================= hooks =================

;; 槽未初始化 → 整篇 open 建状态，写回当前版本槽。
(define (hl-ensure! ctx did path)
  (define ed (session-editor (ctx-session ctx)))
  (unless (editor-document-slot-ref ed did hl)
    (define text (editor-document-string ed did))
    (define ps (plugins-for enabled-attr-plugins path text))
    (define st (make-hash))
    (for ([p (in-list ps)])
      (define-values (s fl) ((plugin-open p) text path))
      (hash-set! st (plugin-name p) (cons s fl)))
    (editor-document-slot-set! ed did hl (hl-state path ps st))))

;; 该版本的全量 fills（各插件按 registry 顺序拼接）。
(define (hl-fills ctx did)
  (define ed (session-editor (ctx-session ctx)))
  (define v (editor-document-slot-ref ed did hl))
  (and v
       (append* (for/list ([p (in-list (hl-state-plugins v))])
                  (cdr (hash-ref (hl-state-states v) (plugin-name p)))))))

;; before-render：对每个真实文件确保状态 + 写回 face 端口。
(define (highlight-hook ctx _args)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (for/fold ([effs '()]) ([did (in-list (editor-document-id-list ed))])
    (define path (doc-path ctx did))
    (cond
      [(not path) effs]
      [else
       (hl-ensure! ctx did path)
       (define fl (hl-fills ctx did))
       (if fl (append effs (list (e-attr-face! did fl face-compose))) effs)])))

;; effect 处理器（feature 自带）：写回 face 端口。
(define (apply-attr-face ctx did fills combine)
  (define doc (editor-document-handle (session-editor (ctx-session ctx)) did))
  (editor-document-handle-set-face! doc #f)
  (editor-document-handle-face-compose! doc fills combine)
  ctx)

(define (register-highlight! r)
  (for/fold ([r r]) ([c (in-list (list (contrib 'effect 'attr-face apply-attr-face)
                                       (contrib 'hook 'highlight (make-hook 'before-render highlight-hook))))])
    (reg-add r c)))
