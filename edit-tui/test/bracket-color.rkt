#lang racket

;;; 括号深度背景 + 括号字符提亮 role + 光标配对。纯配对表与插件 face 两层。

(require rackunit
         racket/string
         "../editor/host-api.rkt"
         "../app/layout.rkt"
         "../plugins/racket-color/plugin.rkt"
         "../lang/racket/api.rkt"
         "../config/theme/default.rkt"
         "../core/face/api.rkt")

;; ---------- 主题：括号 / 配对色由同一层背景色提亮 ----------
(define (role-style role)
  (cadr (assq role bracket-theme)))
(define (fg-luma st)
  (define c (style-fg st))
  (+ (rgb-r c) (rgb-g c) (rgb-b c)))
(define (bg-luma st)
  (define c (style-bg st))
  (+ (rgb-r c) (rgb-g c) (rgb-b c)))
(check-true (style? (role-style 'bracket-depth-0-bracket)))
(check-true (style? (role-style 'bracket-depth-0-match)))
(check-equal? (style-bg (role-style 'bracket-depth-0-bracket))
              (style-bg (role-style 'bracket-depth-0)))
(check-equal? (style-bg (role-style 'bracket-depth-0-match))
              (style-bg (role-style 'bracket-depth-0)))
(check-true (> (fg-luma (role-style 'bracket-depth-0-bracket))
               (bg-luma (role-style 'bracket-depth-0))))
(check-true (> (fg-luma (role-style 'bracket-depth-0-match))
               (fg-luma (role-style 'bracket-depth-0-bracket))))

;; ---------- 配对表：严格栈匹配 ----------
(define pairs (bracket-pair-map "(a [b] c)\n"))
(check-equal? (hash-ref pairs (cons 0 0)) (cons 0 8))
(check-equal? (hash-ref pairs (cons 0 8)) (cons 0 0))
(check-equal? (hash-ref pairs (cons 0 3)) (cons 0 5))
(check-equal? (hash-ref pairs (cons 0 5)) (cons 0 3))

;; 字符串里的括号不参与匹配。
(define string-pairs (bracket-pair-map "(a \"[\" b)\n"))
(check-equal? (hash-ref string-pairs (cons 0 0)) (cons 0 8))
(check-false (hash-ref string-pairs (cons 0 4) #f))

;; 注释里的括号不参与匹配；跨行配对仍然成立。
(define comment-pairs (bracket-pair-map "(a ; [\nb)\n"))
(check-equal? (hash-ref comment-pairs (cons 0 0)) (cons 1 1))
(check-false (hash-ref comment-pairs (cons 0 5) #f))

;; 类型不匹配的右括号不弹栈，也不产生配对。
(define bad-pairs (bracket-pair-map "(a [b)\n"))
(check-equal? (hash-count bad-pairs) 0)

;; ---------- 插件：普通括号角色 / 光标配对 ----------
(define (make-ed text)
  (define engine (make-engine))
  (void (engine-create-buffer! engine 1 "test.rkt" text))
  (void (engine-create-view! engine 1 1))
  (define plugin racket-color-plugin)
  (define ed (make-editor #:engine engine
                          #:registry (make-hook-registry (plugins->hooks (list plugin)))
                          #:plugins (list plugin)))
  (define layout (make-editor-layout #:editor-view 1))
  (define state
    (make-app-state #:plugin-states (plugins->states (list plugin))
                    #:screen (rect 0 0 40 10)
                    #:layout layout))
  (values engine ed state))

(define-values (engine ed state) (make-ed "#lang racket\n(a [b] c)\n"))
(engine-set-view-cursor! engine 1 2 #:column 0)   ; 光标离开括号
(define s1 (run-plugin-syncs ed state))
(check-equal? (face-bg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0)
(check-equal? (face-fg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0-bracket)
(check-equal? (face-bg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1)
(check-equal? (face-fg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1-bracket)

;; 光标到外层 (：它和配对的 ) 都变成更亮的 match role。
(engine-set-view-cursor! engine 1 1 #:column 0)
(define s2 (run-plugin-syncs ed s1))
(check-equal? (face-bg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0)
(check-equal? (face-fg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0-match)
(check-equal? (face-bg (engine-view-face-at engine 1 1 8))
              'bracket-depth-0)
(check-equal? (face-fg (engine-view-face-at engine 1 1 8))
              'bracket-depth-0-match)
(check-equal? (face-bg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1)
(check-equal? (face-fg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1-bracket)

;; 光标移到内层 [：外层恢复普通括号色，内层两端变成 match role。
(engine-set-view-cursor! engine 1 1 #:column 3)
(define s3 (run-plugin-syncs ed s2))
(check-equal? (face-bg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0)
(check-equal? (face-fg (engine-view-face-at engine 1 1 0))
              'bracket-depth-0-bracket)
(check-equal? (face-bg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1)
(check-equal? (face-fg (engine-view-face-at engine 1 1 3))
              'bracket-depth-1-match)
(check-equal? (face-bg (engine-view-face-at engine 1 1 5))
              'bracket-depth-1)
(check-equal? (face-fg (engine-view-face-at engine 1 1 5))
              'bracket-depth-1-match)

;; 未匹配括号：光标停上去也不能凭空产生 match role。
(define-values (engine2 ed2 state2) (make-ed "#lang racket\n(a [b)\n"))
(engine-set-view-cursor! engine2 1 1 #:column 0)
(define s4 (run-plugin-syncs ed2 state2))
(check-equal? (face-bg (engine-view-face-at engine2 1 1 0))
              'bracket-depth-0)
(check-equal? (face-fg (engine-view-face-at engine2 1 1 0))
              'bracket-depth-0-bracket)
(check-equal? (face-bg (engine-view-face-at engine2 1 1 3))
              'bracket-depth-1)
(check-equal? (face-fg (engine-view-face-at engine2 1 1 3))
              'bracket-depth-1-bracket)
(check-equal? (face-bg (engine-view-face-at engine2 1 1 5))
              'bracket-depth-2)
(check-equal? (face-fg (engine-view-face-at engine2 1 1 5))
              'bracket-depth-2-bracket)

(displayln "edit-tui/test/bracket-color.rkt: ok")
