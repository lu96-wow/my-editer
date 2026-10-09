#lang racket

;;; edit/command/session-core.rkt —— core 边界：文档 / 视图 / 几何 / 渲染 / 读
;;;
;;; 唯一（连同 sibling 模块）碰 core 的层。提供会话真身仓的读写桥：
;;;     · 文档 / 视图结构：open / add-document / add-view
;;;     · 读：document ids / view ids / name / did / point
;;;     · 文档级键表（命令挂 document）
;;;     · 几何：layout-place -> placed / rectangle
;;;     · 渲染：core 合成 + 增量
;;;     · session-blank（空 editor）

(require "session-value.rkt"
         "../../core/editor.rkt"
         "../core/area.rkt"
         "../core/layout.rkt"
         "../core/focus.rkt"
         "../core/keymap.rkt")

(provide
 session-blank
 ;; 几何 / 渲染
 session-views session-rectangles session-screen session-patch sync-layout!
 session-focused-did
 ;; 文档 / 视图结构 + 读
 session-open-document session-add-document session-add-view
 session-document-ids session-view-ids-of session-document-name
 session-view-did session-view-point session-view-point-line
 ;; 文档级键表
 session-doc-keys session-doc-add-key session-doc-set-keys
 ;; 保存句柄 / 脏
 session-document-string session-mark-saved session-dirty?)

;;; ---------- 空会话 ----------

(define (session-blank width height [keys '()])
  (session-new (make-blank-editor) #f #f (focus-new #f) width height keys))

;;; ---------- 几何 ----------

(define (session-views s)
  (layout-place (session-layout s) (session-bindings s)
                (lambda (vid) (presentation-visible? (session-presentation s vid)))
                (area 0 0 (session-width s) (session-height s))))

(define (session-rectangles s)
  (for/list ([p (in-list (session-views s))])
    (define vid (placed-vid p))
    (rectangle vid (placed-x p) (placed-y p) (placed-w p) (placed-h p)
               (presentation-depth (session-presentation s vid)))))

(define (session-focused-did s)
  (define vid (session-focus-vid s))
  (and vid (editor-view-document-id (session-ed s) vid)))

;; 本帧几何落到各 view 的视口尺寸（ensure / 上下移动用；幂等）。
(define (sync-layout! s)
  (editor-set-layout! (session-ed s) (session-rectangles s)))

;;; ---------- 渲染 ----------

(define (session-screen s)
  (editor-render-layout (session-ed s) (session-rectangles s)
                        (session-focus-vid s) (session-width s) (session-height s)))

(define (session-patch s old)
  (editor-render-layout-patch (session-ed s) old (session-rectangles s)
                              (session-focus-vid s) (session-width s) (session-height s)))

;;; ---------- 文档 / 视图结构 ----------

(define (session-open-document s doc [keys (kbd)] #:name [name "*scratch*"])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (values (struct-copy session s
            [ed ed*]
            [doc-keymaps (hash-set (session-doc-keymaps s) did keys)])
          did))

(define (session-add-document s doc width height
                              #:name [name "*scratch*"]
                              #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* did) (editor-add-document (session-ed s) doc name))
  (define-values (ed** vid) (editor-add-view ed* did width height
                                             #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s
            [ed ed**]
            [doc-keymaps (hash-set (session-doc-keymaps s) did (kbd))])
          did vid))

(define (session-add-view s did width height
                          #:mode [mode 'clip] #:line-numbers? [line-numbers? #f])
  (define-values (ed* vid) (editor-add-view (session-ed s) did width height
                                            #:mode mode #:line-numbers? line-numbers?))
  (values (struct-copy session s [ed ed*]) vid))

;;; ---------- 读 ----------

(define (session-document-ids s) (editor-document-id-list (session-ed s)))
(define (session-view-ids-of s did) (editor-document-view-list (session-ed s) did))
(define (session-document-name s did) (editor-document-name (session-ed s) did))
(define (session-view-did s vid) (editor-view-document-id (session-ed s) vid))
(define (session-view-point s vid) (editor-view-point (session-ed s) vid))
(define (session-view-point-line s vid) (editor-view-point-line (session-ed s) vid))
(define (session-document-string s did) (editor-document-string (session-ed s) did))

;; 记录「已保存」句柄；核心文档不可变，之后编辑会产生新句柄 → 脏。
(define (session-mark-saved s did)
  (session-set-saved s did (editor-document-handle (session-ed s) did)))

;; 脏 = 有 saved 且当前句柄 != saved（undo 回保存点若命中同一快照会自动变干净）。
(define (session-dirty? s did)
  (define saved (session-saved s did))
  (and saved (not (eq? (editor-document-handle (session-ed s) did) saved))))

;;; ---------- 文档级键表 ----------

(define (session-doc-keys s did) (hash-ref (session-doc-keymaps s) did (kbd)))
(define (session-doc-add-key s did binding spec)
  (struct-copy session s
    [doc-keymaps (hash-set (session-doc-keymaps s) did
                           (keymap-add (hash-ref (session-doc-keymaps s) did (kbd))
                                       binding spec))]))
;; 整表替换（规则层用：文件打开匹配命令表）。
(define (session-doc-set-keys s did km)
  (struct-copy session s [doc-keymaps (hash-set (session-doc-keymaps s) did km)]))
