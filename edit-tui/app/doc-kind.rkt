#lang racket

;;; app/doc-kind.rkt —— document 类型 → 命令表 的绑定（可扩展，不写死）
;;;
;;; 命令表匹配要**穿透到“焦点指向的 document 的类型”**。绑定时机在 document 创建时：
;;;
;;;   (define-doc-kind! 'text #:keymaps (list edit-keys motion-keys))  ; 类型 → 默认表
;;;   (open-document! res "main.rkt" txt #:kind 'text)                 ; document 绑类型
;;;
;;; 自定义 document（文件树 / state 树）只需注册自己的 kind + 小表即可，不用改 app：
;;;
;;;   (define-doc-kind! 'file-tree #:keymaps (list tree-keys))
;;;
;;; 解析链（焦点是 view）：focus → view-buffer → buffer-kind → kind 默认表。
;;;
;;; 除了“类型默认表”，每个 document 还能挂**自己的额外表层**（优先于类型默认表），
;;; 供插件 per-document 追加 / 拔出 / 覆盖 / 还原：
;;;
;;;   (buffer-add-keytable! b kt)      ; 追加一层（最优先）
;;;   (buffer-remove-keytable! b kt)   ; 按身份拔出（= 还原被它盖住的绑定）
;;;
;;; 完整层优先级（由 step.rkt 的 active-keytables 组合）：
;;;
;;;   mode 表  >  document 自己的层  >  kind 默认表  >  全局表
;;;
;;; 为什么不用 core 的 document 槽存类型：core 的槽是**随版本 fork** 的（reset/transform），
;;; 而“文档类型”是文档级元数据、不该随每次编辑变化。所以这里用 eq 哈希按 buffer 身份存，
;;; 也天然满足“类型不因 view 替换 / 文本编辑而丢”。

(require "../command/main.rkt"
         "../../core/editor.rkt")

(provide (struct-out doc-kind)
         define-doc-kind!
         doc-kind->keytable
         buffer-set-kind! buffer-kind
         buffer-add-keytable! buffer-remove-keytable! buffer-clear-keytables! buffer-keytables
         view-kind view-keytables)

;;; ════════════════════════ 类型注册表 ════════════════════════

(struct doc-kind (name keytable) #:transparent)
;; name     : symbol
;; keytable : keytable   该类型的默认命令表（可由多张小表 merge 而成）
;; 暂定：一个类型一张 keytable；将来要“类型内多层”就把 keytable 换成 (listof keytable)。

(define registry (make-hasheq))            ; symbol → doc-kind

;; 定义 / 覆盖一个 document 类型。
;;   #:keymaps  小表列表，自动 merge 成一张 keytable（冲突 → error，作者期就抓错）
;;   #:keytable 直接给一张 keytable（与 #:keymaps 二选一）
(define (define-doc-kind! name #:keymaps [kms '()] #:keytable [keytable #f])
  (unless (symbol? name)
    (error 'define-doc-kind! "类型名要是 symbol：~a" name))
  (define t (cond [keytable keytable]
                  [(null? kms) (make-keytable)]
                  [else (apply make-keytable kms)]))
  (hash-set! registry name (doc-kind name t))
  (void))

;; 类型名 → 命令表（未注册 = 空表，方便“有类型但暂时没绑定”）。
(define (doc-kind->keytable name)
  (define k (and name (hash-ref registry name #f)))
  (if k (doc-kind-keytable k) (make-keytable)))

;;; ════════════════════════ document → 类型 / 额外层 ════════════════════════

(define buffer-kind-tbl  (make-weak-hasheq))   ; buffer → symbol
(define buffer-layer-tbl (make-weak-hasheq))   ; buffer → (listof keytable)

(define (buffer-set-kind! b name) (hash-set! buffer-kind-tbl b name) name)
(define (buffer-kind b) (hash-ref buffer-kind-tbl b #f))

;; 追加 / 拔出 / 清空 per-document 表层（列表，运行时动态变化）。
(define (buffer-add-keytable! b kt)
  (hash-set! buffer-layer-tbl b (cons kt (hash-ref buffer-layer-tbl b '())))
  b)
(define (buffer-remove-keytable! b kt)
  (hash-set! buffer-layer-tbl b (remove kt (hash-ref buffer-layer-tbl b '())))
  b)
(define (buffer-clear-keytables! b)
  (hash-set! buffer-layer-tbl b '())
  b)
(define (buffer-keytables b) (hash-ref buffer-layer-tbl b '()))

;;; ════════════════════════ view → 类型 / 层 ════════════════════════
;;; 焦点是 view；类型和层落在它所属的 buffer 上。view 可被替换，buffer 不变。

(define (view-kind v)   (and v (buffer-kind (view-buffer v))))
(define (view-keytables v) (if v (buffer-keytables (view-buffer v)) '()))
