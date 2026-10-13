#lang racket

;;; edit4-test/sync.rkt —— 双文档映射同步：纯变换 + 会话 + 钩子（双向）+ 命令

(require rackunit racket/list
         "../edit4/plugins/sync/mapping.rkt"
         "../edit4/plugins/sync/transform.rkt"
         "../edit4/plugins/sync/session.rkt"
         "../edit4/plugins/sync/sync.rkt"
         "../edit4/content/model.rkt"
         "../edit4/content/adapter.rkt"
         "../edit4/core/world.rkt"
         "../edit4/core/hook.rkt"
         "../edit4/core/command.rkt"
         "../edit4/core/event.rkt"
         "../edit4/core/dispatch.rkt"
         "../edit4/app.rkt"
         "../edit4/env.rkt"
         "../edit4/layout.rkt"
         "../edit4/view/decor.rkt"
         "../edit4/plugins/sync/mark.rkt")

;;; ---------- 纯变换 ----------

(define m (mapping-by-id 'rkt-zh))

(check-equal? (translate m 'a->b "(define a 3)\n") "(定义 a 3)\n")
(check-equal? (translate m 'b->a "(定义 a 3)\n") "(define a 3)\n")     ; round-trip

;; 字符串 / 注释 / 数字不动；代码位置映射；quoted 符号也映射
(check-equal? (translate m 'a->b "(define \"define\" ; define\n  (list 'define 3))")
              "(定义 \"define\" ; define\n  (list '定义 3))")
;; 块注释跨行不映射
(check-equal? (translate m 'a->b "#| define |# (define x)")
              "#| define |# (定义 x)")

;; 位置映射：源列 7（define 之后）→ 目标列 3（定义 之后）
(define-values (_zh edits) (translate/edits m 'a->b "(define a 3)\n"))
(check-equal? (map-caret edits (cons 0 7)) (cons 0 3))
(check-equal? (map-caret edits (cons 0 3)) (cons 0 3))                ; token 内夹到区间

;;; ---------- 会话 + 钩子：双向同步 ----------

(define lay2 (split 'h 1 (list (child (size 1 #t) (leaf 0 (cons 2 2)))
                               (child (size 1 #t) (leaf 1 (cons 2 2))))))
(define c0 (content-blank))
(define-values (c1 a-did a-vid) (content-add-doc! c0 "(define a 3)\n" 40 10 "en" #f))
(define-values (c2 b-did b-vid) (content-add-doc! c1 "(定义 a 3)\n" 40 10 "zh" #f))
(define w0 (make-world #:layout lay2 #:focus 0
                       #:content (content-bind (content-bind c2 0 a-vid) 1 b-vid)))
(define w1 (session-add w0 (session 0 a-did b-did 'rkt-zh)))

(define (ed-of w) (content-ed (world-content w)))
(define (txt w did) (document-string (ed-of w) did))
(define (caret w vid) (cons (view-line (ed-of w) vid) (view-col (ed-of w) vid)))

;; a 侧插入 → b 更新，且 b 光标同步
(insert! (ed-of w1) a-vid "x")
(define w2 (run-hooks sync-hooks (emit! w1 'after-insert (list a-vid "x"))))
(check-equal? (txt w2 a-did) "x(define a 3)\n")
(check-equal? (txt w2 b-did) "x(定义 a 3)\n")
(check-equal? (caret w2 b-vid) (cons 0 1))

;; b 侧插入 → a 更新（反向）
(insert! (ed-of w2) b-vid "y")
(define w3 (run-hooks sync-hooks (emit! w2 'after-insert (list b-vid "y"))))
(check-equal? (txt w3 b-did) "xy(定义 a 3)\n")
(check-equal? (txt w3 a-did) "xy(define a 3)\n")

;; 导航 → 只搬光标，不改文本
(set-point! (ed-of w3) a-vid 0 0)
(define w4 (run-hooks sync-hooks (emit! w3 'after-nav (list a-vid))))
(check-equal? (caret w4 b-vid) (cons 0 0))
(check-equal? (txt w4 b-did) (txt w3 b-did))

;;; ---------- 命令 ----------

(define (run w cmds) (car (run-commands sync-commands #f w cmds)))

;; sync-open：为焦点文档做翻译文档（存在则打开），新开一个编辑区 + link
(define co0 (content-blank))
(define-values (co1 so-did so-vid) (content-add-doc! co0 "(define a 3)\n" 40 10 "src" #f))
(define wo0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind co1 0 so-vid)))
(define wo1 (run wo0 (list (cmd 'sync-open))))
(check-equal? (length (sessions wo1)) 1)
(check-equal? (length (content-editor-windows (world-content wo1) (world-layout wo1))) 2)  ; 新编辑区
(define so-peer (peer-did (car (sessions wo1)) so-did))
(check-equal? (document-string (content-ed (world-content wo1)) so-peer) "(定义 a 3)\n")
;; 再次 sync-open：已存在 → 只打开/聚焦，不新建
(define wo2 (run wo1 (list (cmd 'sync-open))))
(check-equal? (length (sessions wo2)) 1)
(check-equal? (length (content-editor-windows (world-content wo2) (world-layout wo2))) 2)

;; 新建出来的对也是双向同构：改 peer → 源同步更新
(define p-vid (content-vid-of (world-content wo1) (world-focus wo1)))
(insert! (ed-of wo1) p-vid "z")
(define wo1b (run-hooks sync-hooks (emit! wo1 'after-insert (list p-vid "z"))))
(check-equal? (document-string (ed-of wo1b) so-peer) "z(定义 a 3)\n")
(check-equal? (document-string (ed-of wo1b) so-did) "z(define a 3)\n")

;; 反向：焦点在中文侧 → 生成英文翻译
(define co2 (content-blank))
(define-values (co3 z-did z-vid) (content-add-doc! co2 "(定义 b 4)\n" 40 10 "zh" #f))
(define wz0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind co3 0 z-vid)))
(define wz1 (run wz0 (list (cmd 'sync-open))))
(define z-peer (peer-did (car (sessions wz1)) z-did))
(check-equal? (document-string (content-ed (world-content wz1)) z-peer) "(define b 4)\n")

;; 文件文档（有 path）也能做翻译（peer 仍是内存文档）
(define fp0 (content-blank))
(define-values (fp1 f-did f-vid) (content-add-doc! fp0 "(lambda (x) x)\n" 40 10 "code" (string->path "/tmp/code.rkt")))
(define wf0 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind fp1 0 f-vid)))
(define wf1 (run wf0 (list (cmd 'sync-open))))
(define f-peer (peer-did (car (sessions wf1)) f-did))
(check-equal? (document-string (content-ed (world-content wf1)) f-peer) "(函数 (x) x)\n")

;; sync-unlink：解除焦点文档所在 session
(define wu (run w3 (list (cmd 'sync-unlink))))
(check-false (session-for-did wu a-did))

;;; ---------- 对应词高亮（decor）----------

(set-point! (ed-of w3) a-vid 0 3)                     ; 光标在 define 内
(apply-faces! (ed-of w3) (list sync-mark-decor) w3)
(check-eq? (document-face-at (ed-of w3) a-did 0 3) 'sync-mark)
(check-eq? (document-face-at (ed-of w3) a-did 0 8) 'sync-mark)   ; define 末尾
(check-false (document-face-at (ed-of w3) a-did 0 0))            ; 'x' 不在映射词里
(check-false (document-face-at (ed-of w3) a-did 0 2))            ; '(' 不是词

;;; ---------- C-o 前缀（经真实 Environment keymap） ----------

(define env (app-environment))
(define (send w ev)
  (car (call-with-values
        (lambda ()
          (dispatch (environment-commands env) (environment-scopes env)
                    (environment-keymap env) (ctx ev (cons 80 24) #f) w))
        list)))

(define we2 (make-world #:layout (leaf 0 (cons 2 2)) #:focus 0 #:content (content-bind co1 0 so-vid)))
(define wp (send we2 (key-event 'o '(ctrl))))
(check-eq? (world-prefix wp) 'sync)                 ; C-o 进前缀
(define wo (send wp (text-event "o")))             ; C-o o → sync-open
(check-equal? (length (sessions wo)) 1)
(check-false (world-prefix wo))                     ; 跑完清前缀
(define wc (send wp (key-event 'escape '())))           ; C-o Esc → 取消
(check-false (world-prefix wc))

(displayln "edit4/sync.rkt: all tests passed")
