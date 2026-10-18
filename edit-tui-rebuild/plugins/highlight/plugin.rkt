#lang racket

;;; plugins/highlight/plugin.rkt —— 语法高亮插件（hook 驱动）
;;;
;;; layer  : plugins/highlight
;;; effect : 只发 set-faces-effect（core 端口写回在 effects/interpreter.rkt）
;;;
;;; 它不做任何“流程”：只是两条 hook
;;;
;;;   document-opened  -> 初次上色
;;;   after-edit       -> 文本改了，重新上色
;;;
;;; 两者都先比对版本 token（core 的 opaque document）：没变就直接返回，
;;; 所以“光标移动 / 无关的 effect”不会触发重扫。
;;;
;;; **只对 Racket 文件生效**（插件级 applies?）：
;;;   路径后缀 .rkt / .rktl / .scratch，或 doc 的 mode 是 'racket。
;;;   其他文件（.txt / .md …）不会被上色 —— 这就是“匹配文件类型启用”。
;;;
;;; 上色文本由 lex.rkt 算（纯），本文件只负责：
;;;   · 过滤掉 infrastructure 文档（状态栏 / 输入栏 / 插件面板）；
;;;   · 记住每个 doc 上次上色的版本；
;;;   · 发一个整篇重设 face 的 effect。
;;;
;;; 暂定：整篇重扫。要增量时只改 lex.rkt 的接口内部（fills 形状不变）。

(provide highlight-plugin)

(require racket/path
         "../../base/id.rkt"
         "../../base/transition.rkt"
         "../../base/effect.rkt"
         "../../model/state.rkt"
         "../../model/workspace.rkt"
         "../../effects/engine.rkt"
         "../../env/environment.rkt"
         "../../env/hook.rkt"
         "../../env/plugin.rkt"
         "lex.rkt")

(define store-key 'highlight)

;;; ════════════════ 适用范围（插件级 applies?） ════════════════

(define racket-extensions '("rkt" "rktl" "rktd" "scratch"))

(define (racket-path? path)
  (and path
       (let ([e (filename-extension path)])
         (and e
              (for/or ([ext (in-list racket-extensions)])
                (string=? ext (string-downcase (bytes->string/utf-8 e))))))))

;; doc 是不是 Racket 文件：模式优先（doc-type 可以把它设成 'racket），否则看路径后缀。
(define (racket-doc? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm
       (or (eq? (doc-meta-mode dm) 'racket)
           (racket-path? (doc-meta-path dm)))))

(define (highlighted-version state did)
  (hash-ref (plugin-state state store-key (hash)) did #f))

;; 只给“真实文档”上色（面板 / 状态栏 / 输入栏都是 internal）。
(define (highlightable-doc? state did)
  (define dm (workspace-doc (state-workspace state) did))
  (and dm (not (doc-meta-internal? dm)) (racket-doc? state did)))

;; 给一个 doc 上色：版本没变就什么都不做。
(define (highlight-doc state ev did)
  (define cur (engine-view-doc-version ev did))
  (cond
    [(not (and did cur (highlightable-doc? state did))) (transition-pure state)]
    [(engine-version=? cur (highlighted-version state did)) (transition-pure state)]
    [else
     (define text (engine-view-doc-text ev did))
     (define fills (lex-fills (or text "")))
     (transition
      (plugin-state-set state store-key
                        (hash-set (plugin-state state store-key (hash)) did cur))
      (list (set-faces-effect did fills)))]))

(define (on-doc state ev args)
  (highlight-doc state ev (car args)))

;; 插件级开关注入：不想要高亮时传 #:enabled? #f（例如做“纯文本模式”的 demo）。
(define (highlight-plugin #:enabled? [enabled? #t])
  (make-plugin
   'highlight
   #:hooks (if enabled?
               (list (make-hook 'document-opened on-doc
                                #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args)))))
                     (make-hook 'after-edit on-doc
                                #:when (λ (s ev args) (and (pair? args) (racket-doc? s (car args))))))
               '())))
