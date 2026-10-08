#lang racket

;;; lab-rebuild/builtin/translate.rkt —— 对照翻译（一个文档 ↔ 另一个文档）。
;;;
;;; 针对当前文档另开一个「译文文档」，两边**任意一侧编辑都同步到另一侧**：
;;;   · 内容转换：after-edit（用户编辑）→ 自定义 effect → editor-view-assign! 写对侧；
;;;                assign 不触发 after-edit ⇒ 天然单向、无回环，不需要 origin 标志。
;;;   · 视口同步：before-render（每帧对账 anchor）→ 自定义 effect → editor-view-set-anchor!。
;;;                用「上次 anchor 快照」判定哪侧动了（而非只看焦点），
;;;                所以鼠标滚轮停在非焦点窗格上也能反向同步；两侧都动时用焦点裁决。
;;;
;;; 里外都用 effect，不改 kernel：effect 是数据（fx 可自造 tag），
;;; apply-effect 先查 registry 的 'effect 贡献，插件的 handler 就是写入点
;;; （与 highlight / mouse 同款）。状态放 runtime.services['translate]。
;;;
;;; 词法翻译保持行数不变（译词不含换行），因此视口按 buffer 行 1:1 对应。

(require racket/string
         "../kernel/api.rkt"
         "../config/translate.rkt")

(provide register-translate! (struct-out tr) translate-string)

;;; ================= 状态（service，per-runtime） =================

;; 一对文档/视图：src 是「原文档」，dst 是「译文档」。
(struct tpair (src-did dst-did src-vid dst-vid) #:transparent)

(struct tr (pairs      ; (listof tpair)        所有配对（渲染 / 清理遍历）
            did->pair  ; hash did -> tpair     内容转换按 did 查
            fwd bwd    ; hash string -> string 正向 / 反向词典
            anchors)   ; hash vid -> (cons line display-col)  上次视口锚点
  #:mutable #:transparent)

;; 视口锚点 (buffer 行 . 显示列)。
(define (anchor-of ed v)
  (call-with-values (λ () (editor-view-anchor ed v)) cons))

;; 记下某视图当前锚点为「已见」。
(define (remember! tr ed v)
  (hash-set! (tr-anchors tr) v (anchor-of ed v)))

;; 配对的对侧 did。
(define (tr-target-did pair did)
  (if (eqv? did (tpair-src-did pair)) (tpair-dst-did pair) (tpair-src-did pair)))

;; 移除一对（内容对 + 视图对 + anchor）。
(define (translate-forget! tr pair)
  (hash-remove! (tr-did->pair tr) (tpair-src-did pair))
  (hash-remove! (tr-did->pair tr) (tpair-dst-did pair))
  (set-tr-pairs! tr (remq pair (tr-pairs tr)))
  (hash-remove! (tr-anchors tr) (tpair-src-vid pair))
  (hash-remove! (tr-anchors tr) (tpair-dst-vid pair)))

;;; ================= 词法翻译（保持空白 / 换行 / 行数） =================

;; 「一个词」：字母 / 数字 / _ / $ / 非 ASCII（CJK 落在最后一类，于是「打印」是一个词）。
;; 只做整词替换：printf → 打印，printf_safe 不受影响。
(define (word-char? c)
  (or (char-alphabetic? c) (char-numeric? c)
      (memv c '(#\_ #\$))
      (>= (char->integer c) 128)))

;; h : hash string -> string；未命中原样保留。
(define (translate-string h text)
  (define n (string-length text))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i n) (string-append* (reverse acc))]
      [(word-char? (string-ref text i))
       (let scan ([j i])
         (cond
           [(and (< j n) (word-char? (string-ref text j))) (scan (add1 j))]
           [else
            (define tok (substring text i j))
            (loop j (cons (hash-ref h tok tok) acc))]))]
      [else (loop (add1 i) (cons (string (string-ref text i)) acc))])))

;;; ================= 内容转换：after-edit =================

;; 用户编辑了某文档（vid）：若它属于一对，则按方向翻译全文，写到对侧。
;; 写回走 assign（不触发 after-edit），所以只发生一次，绝不回环。
(define (translate-edit-hook ctx args)
  (match-define (list vid _changes) args)
  (define tr (service-ref ctx 'translate))
  (cond
    [(not tr) '()]
    [else
     (define s (ctx-session ctx))
     (define ed (session-editor s))
     (define did (editor-view-document-id ed vid))
     (define pair (hash-ref (tr-did->pair tr) did #f))
     (cond
       [(not pair) '()]
       [else
        (define tdid (tr-target-did pair did))
        (define tvid (car (editor-document-view-list ed tdid)))
        (define src (editor-document-string ed did))
        (define dict (if (eqv? did (tpair-src-did pair)) (tr-fwd tr) (tr-bwd tr)))
        (list (fx 'translate-write tvid (translate-string dict src)))])]))

;;; ================= 视口同步：before-render =================

;; 每帧对账：某侧 anchor 变了就推给对侧；两侧都变用焦点裁决；都没变不动。
(define (translate-render-hook ctx _args)
  (define tr (service-ref ctx 'translate))
  (cond
    [(not tr) '()]
    [else
     (define s (ctx-session ctx))
     (define ed (session-editor s))
     (define focus (session-focus-vid s))
     (append*
      (for/list ([p (in-list (tr-pairs tr))])
        (define a (tpair-src-vid p))
        (define b (tpair-dst-vid p))
        (define ca (anchor-of ed a))
        (define cb (anchor-of ed b))
        (define a? (not (equal? ca (hash-ref (tr-anchors tr) a #f))))
        (define b? (not (equal? cb (hash-ref (tr-anchors tr) b #f))))
        (cond
          [(and a? b?)
           (cond
             [(eqv? focus a) (hash-set! (tr-anchors tr) a ca)
                             (list (fx 'translate-anchor b (car ca) (cdr ca)))]
             [(eqv? focus b) (hash-set! (tr-anchors tr) b cb)
                             (list (fx 'translate-anchor a (car cb) (cdr cb)))]
             [else (hash-set! (tr-anchors tr) a ca)
                   (hash-set! (tr-anchors tr) b cb)
                   '()])]
          [a? (hash-set! (tr-anchors tr) a ca)
              (list (fx 'translate-anchor b (car ca) (cdr ca)))]
          [b? (hash-set! (tr-anchors tr) b cb)
              (list (fx 'translate-anchor a (car cb) (cdr cb)))]
          [else '()])))]))

;;; ================= effect 处理器（feature 自带 = 写入点） =================

;; 写对侧内容。assign = 程序写入（封口、不记步、不触发 after-edit）；
;; 写完后刷新该文档所有视图的 anchor 快照，避免下一帧把它误判成「用户滚动」。
(define (apply-translate-write ctx tvid text)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (editor-view-assign! ed tvid text)
  (define tr (service-ref ctx 'translate))
  (when tr
    (define did (editor-view-document-id ed tvid))
    (for ([v (in-list (editor-document-view-list ed did))]) (remember! tr ed v)))
  ctx)

;; 设对侧视口锚点，并记下**实际**落位（set-anchor 会按目标文档自己的 mode 夹取）。
(define (apply-translate-anchor ctx vid line dc)
  (define s (ctx-session ctx))
  (define ed (session-editor s))
  (editor-view-set-anchor! ed vid line dc)
  (define tr (service-ref ctx 'translate))
  (when tr (remember! tr ed vid))
  ctx)

;;; ================= 开 / 关 =================

;; 针对当前编辑文档另开译文文档（+ 视图），登记配对。已配对则不重复开。
(define (apply-translate-open ctx)
  (define s (ctx-session ctx))
  (define tr (service-ref ctx 'translate))
  (define src-vid (session-edit-vid s))
  (define ed (session-editor s))
  (cond
    [(or (not tr) (not src-vid)) ctx]
    [(hash-ref (tr-did->pair tr) (editor-view-document-id ed src-vid) #f) ctx]
    [else
     (define src-did (editor-view-document-id ed src-vid))
     (define out (translate-string (tr-fwd tr) (editor-document-string ed src-did)))
     (define name (format "~a 译" (editor-document-name ed src-did)))
     (define-values (ed2 did) (editor-add-document ed out name))
     (define-values (ed3 vid)
       (editor-add-view ed2 did (session-width s) (max 1 (sub1 (session-height s)))
                        #:line-numbers? #t))
     (define pair (tpair src-did did src-vid vid))
     (hash-set! (tr-did->pair tr) src-did pair)
     (hash-set! (tr-did->pair tr) did pair)
     (set-tr-pairs! tr (cons pair (tr-pairs tr)))
     (remember! tr ed3 src-vid)
     (remember! tr ed3 vid)
     ;; 原文 | 译文 放进**同一个叶子**（固定左右布局），外层把它当一个窗格。
     (define fr (frame-set-leaf (session-frame s) src-vid
                                (leaf (isplit* 'lr src-vid vid) 'edit)))
     (ctx-with-session ctx
       (struct-copy session s
         [editor ed3] [frame fr]
         [focus (focus-set (session-focus s) vid)]))]))

;; 关掉当前文档所属配对（连同译文档的视图 / frame 叶）。
(define (apply-translate-close ctx)
  (define s (ctx-session ctx))
  (define tr (service-ref ctx 'translate))
  (define cur (session-edit-vid s))
  (define ed (session-editor s))
  (define pair (and tr cur (hash-ref (tr-did->pair tr) (editor-view-document-id ed cur) #f)))
  (cond
    [(not pair) ctx]
    [else
     (define cur-did (editor-view-document-id ed cur))
     (define tdid (tr-target-did pair cur-did))
     (define keep-vid (if (eqv? tdid (tpair-src-did pair)) (tpair-dst-vid pair) (tpair-src-vid pair)))
     (define tgt-vids (editor-document-view-list ed tdid))
     (define fr (for/fold ([fr (session-frame s)]) ([v (in-list tgt-vids)]) (frame-remove fr v)))
     (define ed2 (editor-close-document ed tdid))
     (path-table-remove! (session-paths s) tdid)
     (translate-forget! tr pair)
     (define ctx1 (ctx-with-session ctx
                    (struct-copy session s
                      [editor ed2] [frame fr]
                      [focus (focus-set (session-focus s) keep-vid)])))
     ;; 直接关文档也要走 document-closed（特性靠它清影子状态），与 kernel 的 close 一致。
     (run-notify ctx1 'document-closed (list tdid))]))

;;; ================= 生命周期 / 注册 =================

;; 文档关闭 → 清配对（视图已不在 editor 里，按登记的 vid 清 anchor）。
(define (translate-closed-hook ctx args)
  (define tr (service-ref ctx 'translate))
  (when tr
    (define pair (hash-ref (tr-did->pair tr) (car args) #f))
    (when pair (translate-forget! tr pair)))
  '())

(define (translate-init ctx)
  (service-put ctx 'translate
               (tr '()
                   (make-hash)
                   (for/hash ([p (in-list translate-pairs)]) (values (car p) (cdr p)))
                   (for/hash ([p (in-list translate-pairs)]) (values (cdr p) (car p)))
                   (make-hash))))

(define (cmd-translate-open ctx ev) (list (fx 'translate-open)))
(define (cmd-translate-close ctx ev) (list (fx 'translate-close)))

(define (register-translate! r)
  (for/fold ([r r])
            ([c (in-list
                 (list (contrib 'init 'translate 0 translate-init)
                       (contrib 'effect 'translate-write  0 apply-translate-write)
                       (contrib 'effect 'translate-anchor 0 apply-translate-anchor)
                       (contrib 'effect 'translate-open   0 apply-translate-open)
                       (contrib 'effect 'translate-close  0 apply-translate-close)
                       (contrib 'hook 'translate-edit   0 (make-hook 'after-edit translate-edit-hook))
                       (contrib 'hook 'translate-render 0 (make-hook 'before-render translate-render-hook))
                       (contrib 'hook 'translate-closed 0 (make-hook 'document-closed translate-closed-hook))
                       (contrib 'binding 'translate-open  0 (keybinding 'global (key 't 'ctrl) 'translate-open))
                       (contrib 'binding 'translate-close 0 (keybinding 'global (key 't 'alt) 'translate-close))
                       (contrib 'command 'translate-open  0 cmd-translate-open)
                       (contrib 'command 'translate-close 0 cmd-translate-close)))])
    (reg-add r c)))
