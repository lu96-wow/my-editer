#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt"
         "../atom/attr.rkt" "../atom/change.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../viewport/window.rkt"
         "state.rkt" "write.rkt" "neutral.rkt" "reaction.rkt" rackunit)

;;; platform/program.rkt —— 程序面：编辑原语 + 显式视图命令
;;;
;;; 编辑只有一个原语 **editor-command**（选区 + op + 可选属性计划）/ **editor-command-batch**（现成 change）：
;;; 策略（目标 / 上下文 / 守卫 / 反应 / 记账）全是**参数**，不是函数身份。
;;; editor-edit-at / editor-edit-at-batch / editor-edit / editor-view-edit 都是它的薄封装。
;;;
;;; 视图命令都是「只动指定的那个 view」，绝不镜像、不抢焦点、不 ensure；
;;; 用户命令（leader/ensure/账本）在 command.rkt。

(provide
 editor-command
 editor-command-batch
 editor-edit-at
 editor-edit-at-batch
 ;; 编辑动作（editor 级，可传的值；op : editor did selection → desc）
 edit-insert edit-insert-char edit-newline edit-backspace edit-delete edit-splice
 ;; 显式 view 命令（程序面：按 vid 定位，只动指定 view，不经过焦点）
 editor-view-set-point
 editor-view-put-window
 editor-view-set-selections
 editor-view-add-selections
 editor-view-remove-selections
 editor-view-collapse-selections
 editor-view-map-selections
 editor-view-map-primary
 editor-view-map-points
 editor-view-add-selection
 editor-view-remove-selection
 editor-view-set-primary
 editor-view-set-primary-index
 editor-view-selection-member?
 editor-view-set-size
 editor-view-set-mode
 editor-view-set-top-line
 editor-view-set-top-seg
 editor-view-set-left-col
 editor-view-set-sync
 editor-view-set-document
 ;; focus 糖（用户面便捷；程序面请用上面的 editor-view-*）
 editor-set-point
 editor-put-window
 editor-set-selections
 editor-add-selections
 editor-remove-selections
 editor-collapse-selections
 editor-map-selections
 editor-map-primary
 editor-map-points
 editor-add-selection
 editor-remove-selection
 editor-set-primary
 editor-set-primary-index
 editor-selection-member?
 editor-set-mode
 editor-set-size
 editor-set-top-line
 editor-set-top-seg
 editor-set-left-col
 editor-set-sync
 editor-set-document
 editor-set-document-name
 ;; 属性写（程序面：改 document 的属性，不碰文本/光标）
 editor-apply-attrs
 editor-put-attr
 editor-remove-attr)

;;; ---------- 编辑原语：策略全显式 ----------
;; op   : (or/c #f (editor did selection → (or/c #f edit-desc)))
;; attrs: (or/c #f (editor did (listof edit-desc) → (listof attr-desc)))
;;
;; 正交策略（都是数据，不是函数身份）：
;;   #:view       目标 view（默认焦点 view）
;;   #:selection  编辑上下文（默认该 view 的选区集）
;;   #:attrs      属性计划：在文本 descs 夹紧后求值，坐标为「文本生效之后」
;;   #:trusted?   是否跳过 read-only 守卫（默认 #f = 守）
;;   #:reaction   'none（只夹紧）/ 'map（同文档各 view free 映射）/
;;                'leader（本 view 推进到插入后 + ensure，其余按 sync）
;;   #:record?    是否记一步账本（整批记一步）
;;   #:pre-point  记账用的编辑前光标（默认该 view 的 primary head）
;; 返回 (values editor (or/c #f change-report))。

;; 两条 desc 的区间是否相交（半开）
(define (desc-overlap? d1 d2)
  (and (point<? (edit-desc-start d1) (edit-desc-end d2))
       (point<? (edit-desc-start d2) (edit-desc-end d1))))

;; 两个选区的包络（方向取正向）
(define (selection-hull a b)
  (define-values (as ae) (selection-range a))
  (define-values (bs be) (selection-range b))
  (selection (if (point<? bs as) bs as) (if (point<? ae be) be ae)))

;; 多选区：对每个选区算 desc；重叠（backspace/delete 超出选区，相邻就撞上）的合并成包络
;; 再重算 op，直到 desc 两两不相交。op : editor did selection → desc/#f。
(define (coalesce-descs ed did sels op)
  (define pairs
    (filter values (for/list ([s (in-list sels)])
                     (define d (op ed did s))
                     (and d (cons s d)))))
  (let loop ([ps pairs])
    (cond
      [(null? ps) '()]
      [else
       (define p (car ps))
       (define conflicts (filter (lambda (q) (desc-overlap? (cdr p) (cdr q))) (cdr ps)))
       (cond
         [(null? conflicts) (cons (cdr p) (loop (cdr ps)))]
         [else
          (define group (cons p conflicts))
          (define hull (for/fold ([h (car (car group))]) ([g (in-list (cdr group))])
                         (selection-hull h (car g))))
          (define d (op ed did hull))
          (loop (if d
                    (cons (cons hull d) (remove* conflicts (cdr ps)))
                    (remove* conflicts (cdr ps))))])])))

;; 命令的后半：反应 + 记账 + report（single / batch / attr 共用）。
(define (editor-run-change ed ch vid reaction record? pre guard?)
  (define did (editor-view-document-id ed vid))
  (define-values (ed* res) (editor-apply-change ed did ch guard?))
  (cond
    [(not res) (values ed #f)]
    [else
     (define d* (editor-document ed* did))
     (define tds (change-result-applied-texts res))
     (define ed** (case reaction
                    [(none)   (editor-clamp-views ed* d*)]
                    [(map)    (editor-map-views ed* d* tds)]
                    [(leader) (editor-leader-view ed* vid d* tds)]
                    [else (error 'editor-command "reaction 必须是 'none / 'map / 'leader，得到 ~a" reaction)]))
     (define ed*** (if record?
                       (editor-record-history ed** did
                                              (list (change-result-replay res))
                                              (change-result-undo res)
                                              pre)
                       ed**))
     (values ed*** (change-report tds (change-result-applied-attrs res)))]))

;; 给一串选区与 op（+ 可选属性计划），算 change 再施加。
(define (editor-command ed op
                        #:attrs [attr-plan #f]
                        #:view [vid (view-id (editor-focused-view ed))]
                        #:selection [selection #f]
                        #:trusted? [trusted? #f]
                        #:reaction [reaction 'none]
                        #:record? [record? #f]
                        #:pre-point [pre-point #f])
  (define v (editor-view-ref ed vid))
  (define did (editor-view-document-id ed vid))
  (define sels (or selection (window-selections (view-window v))))
  (define descs (if op (coalesce-descs ed did sels op) '()))
  (define eff (buffer-clamp-edit-descs (editor-buffer ed did) descs))
  (define attrs (if attr-plan (or (attr-plan ed did eff) '()) '()))
  (define pre (or pre-point (selection-point (window-primary (view-window v)))))
  (editor-run-change ed (change eff attrs) vid reaction record? pre (not trusted?)))

;; 给一个已算好的 change 直接施加。
(define (editor-command-batch ed ch
                        #:view [vid (view-id (editor-focused-view ed))]
                        #:trusted? [trusted? #f]
                        #:reaction [reaction 'none]
                        #:record? [record? #f]
                        #:pre-point [pre-point #f])
  (define v (editor-view-ref ed vid))
  (define pre (or pre-point (selection-point (window-primary (view-window v)))))
  (editor-run-change ed ch vid reaction record? pre (not trusted?)))

;;; ---------- 编辑动作（editor 级，可传的值）----------
;;; op : editor did selection → (or/c #f edit-desc)。只**算** desc，不施加；
;;; 转发给 doc 层的 buffer 级动作（buffer-op-*）。编辑原语只认这一种形状。

(define (edit-insert text)
  (lambda (ed did sel) ((buffer-op-insert text) (editor-buffer ed did) sel)))
(define (edit-insert-char ch) (edit-insert (string ch)))
(define (edit-newline)       (edit-insert "\n"))
(define (edit-backspace)
  (lambda (ed did sel) ((buffer-op-backspace) (editor-buffer ed did) sel)))
(define (edit-delete)
  (lambda (ed did sel) ((buffer-op-delete) (editor-buffer ed did) sel)))
;; 通用逃生门：显式区间的替换（程序化编辑）
(define (edit-splice start end text)
  (lambda (_ed _bid _sel) (edit-desc start end text)))

;;; ---------- 薄封装：按 did + 位置 / 批量 descs（程序面） ----------

;; 按 did 取它任一 view 的 vid。buffer 没有任何 view 时无法承载显示语义（reaction），
;; 也没有可取的选区上下文 → 明确报错。
(define (document-vid who ed did)
  (define v (view-of-document ed did))
  (unless v (error who "buffer ~a 没有任何 view，无法编辑" did))
  (view-id v))

(define (editor-edit-at ed did p op
                        #:reaction [reaction 'none]
                        #:trusted? [trusted? #f]
                        #:record? [record? #f])
  (editor-command ed op
                  #:view (document-vid 'editor-edit-at ed did)
                  #:selection (list (caret p))
                  #:trusted? trusted?
                  #:reaction reaction
                  #:record? record?
                  #:pre-point p))

(define (editor-edit-at-batch ed did descs
                              #:reaction [reaction 'none]
                              #:trusted? [trusted? #f]
                              #:record? [record? #f])
  (editor-command-batch ed (change/edits descs)
                        #:view (document-vid 'editor-edit-at-batch ed did)
                        #:trusted? trusted?
                        #:reaction reaction
                        #:record? record?
                        #:pre-point (edits-min-start descs)))

;; 批量没有唯一编辑点；pre-point 取最左（文档序）施加点，撤销后光标落到最靠前的改动处。
(define (edits-min-start ds)
  (for/fold ([p #f]) ([d (in-list ds)])
    (define s (edit-desc-start d))
    (if (or (not p) (point<? s p)) s p)))


;;; ---------- 显式视图命令（程序面：只动一个 view，不镜像、不抢焦点） ----------
;; 全部按 vid 定位，绝不读也不改 focus；同 document 其它 view 一律不动。

(define (view-window-of ed vid) (view-window (editor-view-ref ed vid)))

;; 裸写视图态（光标/视口/模式，只夹紧、不同步）；读口是 editor-view-window。
;; **不改文档**：w 的 document 必须就是该 view 当前的 document；换文档用 editor-view-set-document。
(define (editor-view-put-window ed vid w)
  (define v (editor-view-ref ed vid))
  (unless (eq? (window-document w) (view-document v))
    (error 'editor-view-put-window
           "window 的 document 与该 view 不符；换文档请用 editor-view-set-document"))
  (editor-put-view ed vid w))
(define (editor-put-window ed w)
  (editor-view-put-window ed (view-id (editor-focused-view ed)) w))

(define (editor-view-set-point ed vid p)
  (editor-put-view ed vid (window-set-point (view-window-of ed vid) p)))

(define (editor-view-set-selections ed vid sels [primary-index 0])
  (editor-put-view ed vid (window-set-selections (view-window-of ed vid) sels primary-index)))
(define (editor-view-add-selections ed vid sels #:primary? [primary? #f])
  (editor-put-view ed vid (window-add-selections (view-window-of ed vid) sels #:primary? primary?)))
(define (editor-view-remove-selections ed vid sels)
  (editor-put-view ed vid (window-remove-selections (view-window-of ed vid) sels)))

;; 回单光标：把该 view 的选区坍缩成 primary 处的一个空选区
(define (editor-view-collapse-selections ed vid)
  (define w (view-window-of ed vid))
  (editor-put-view ed vid (window-set-point w (window-point w))))

(define (editor-view-set-size ed vid height width)
  (editor-put-view ed vid (window-set-size (view-window-of ed vid) height width)))

(define (editor-view-set-mode ed vid mode)
  (editor-put-view ed vid (window-set-mode (view-window-of ed vid) mode)))

(define (editor-view-set-top-line ed vid n)
  (editor-put-view ed vid (window-set-top-line (view-window-of ed vid) n)))

(define (editor-view-set-top-seg ed vid n)
  (editor-put-view ed vid (window-set-top-seg (view-window-of ed vid) n)))

(define (editor-view-set-left-col ed vid n)
  (editor-put-view ed vid (window-set-left-col (view-window-of ed vid) n)))

;; 结构变换：换指定 view 的同步策略 / 属主；不触发同步。
(define (editor-view-set-sync ed vid sync)
  (editor-set-view-sync ed vid sync))
(define (editor-view-set-document ed vid did)
  (editor-set-view-document ed vid did))

;;; ---------- 选区集合算子（程序面：只动指定 view） ----------

;; 对每个选区施加 f（selection → selection），再规范化；primary 保持。
(define (editor-view-map-selections ed vid f)
  (editor-put-view ed vid (window-map-selections (view-window-of ed vid) f)))
;; 只对 primary 施加 f；其余不动。
(define (editor-view-map-primary ed vid f)
  (editor-put-view ed vid (window-map-primary (view-window-of ed vid) f)))
;; 对每个选区 head 施加 f（point → point），坍缩成光标。
(define (editor-view-map-points ed vid f)
  (editor-put-view ed vid (window-map-points (view-window-of ed vid) f)))
(define (editor-view-add-selection ed vid s #:primary? [primary? #f])
  (editor-put-view ed vid (window-add-selection (view-window-of ed vid) s #:primary? primary?)))
(define (editor-view-remove-selection ed vid s)
  (editor-put-view ed vid (window-remove-selection (view-window-of ed vid) s)))
(define (editor-view-set-primary ed vid s)
  (editor-put-view ed vid (window-set-primary (view-window-of ed vid) s)))
(define (editor-view-set-primary-index ed vid i)
  (editor-put-view ed vid (window-set-primary-index (view-window-of ed vid) i)))
(define (editor-view-selection-member? ed vid s)
  (window-selection-member? (view-window-of ed vid) s))

;;; ---------- focus 糖（用户面便捷） ----------

(define (editor-set-point ed p)
  (editor-view-set-point ed (view-id (editor-focused-view ed)) p))

(define (editor-set-selections ed sels [primary-index 0])
  (editor-view-set-selections ed (view-id (editor-focused-view ed)) sels primary-index))
(define (editor-add-selections ed sels #:primary? [primary? #f])
  (editor-view-add-selections ed (view-id (editor-focused-view ed)) sels #:primary? primary?))
(define (editor-remove-selections ed sels)
  (editor-view-remove-selections ed (view-id (editor-focused-view ed)) sels))
(define (editor-collapse-selections ed)
  (editor-view-collapse-selections ed (view-id (editor-focused-view ed))))

(define (editor-set-mode ed mode)
  (editor-view-set-mode ed (view-id (editor-focused-view ed)) mode))

(define (editor-set-size ed height width)
  (editor-view-set-size ed (view-id (editor-focused-view ed)) height width))

(define (editor-set-top-line ed n)
  (editor-view-set-top-line ed (view-id (editor-focused-view ed)) n))

(define (editor-set-top-seg ed n)
  (editor-view-set-top-seg ed (view-id (editor-focused-view ed)) n))

(define (editor-set-left-col ed n)
  (editor-view-set-left-col ed (view-id (editor-focused-view ed)) n))

(define (editor-set-sync ed sync)
  (editor-view-set-sync ed (view-id (editor-focused-view ed)) sync))
(define (editor-set-document ed did)
  (editor-view-set-document ed (view-id (editor-focused-view ed)) did))

;; 选区集合算子的 focus 糖。
(define (editor-map-selections ed f)
  (editor-view-map-selections ed (view-id (editor-focused-view ed)) f))
(define (editor-map-primary ed f)
  (editor-view-map-primary ed (view-id (editor-focused-view ed)) f))
(define (editor-map-points ed f)
  (editor-view-map-points ed (view-id (editor-focused-view ed)) f))
(define (editor-add-selection ed s #:primary? [primary? #f])
  (editor-view-add-selection ed (view-id (editor-focused-view ed)) s #:primary? primary?))
(define (editor-remove-selection ed s)
  (editor-view-remove-selection ed (view-id (editor-focused-view ed)) s))
(define (editor-set-primary ed s)
  (editor-view-set-primary ed (view-id (editor-focused-view ed)) s))
(define (editor-set-primary-index ed i)
  (editor-view-set-primary-index ed (view-id (editor-focused-view ed)) i))
(define (editor-selection-member? ed s)
  (editor-view-selection-member? ed (view-id (editor-focused-view ed)) s))

;;; ---------- buffer 元数据 ----------

(define (editor-set-document-name ed did name)
  (editor-put-document-name ed did name))

;;; ---------- 属性写（改 document 的属性；不碰文本，光标自然不动） ----------
;; 走 change 命令：与文本编辑同一条路径；#:record? 默认 #f（程序面，与 editor-edit-at 一致），
;; 用户面（如标记只读）请传 #:record? #t 以入账本、可撤销。

(define (editor-apply-attrs ed did attrs #:record? [record? #f])
  (editor-command-batch ed (change/attrs attrs)
                        #:view (document-vid 'editor-apply-attrs ed did)
                        #:record? record?))

(define (editor-put-attr ed did start end key val #:record? [record? #f])
  (editor-apply-attrs ed did (list (attr-set start end key val)) #:record? record?))
(define (editor-remove-attr ed did start end key #:record? [record? #f])
  (editor-apply-attrs ed did (list (attr-remove start end key)) #:record? record?))

;;; ---------- 测试 ----------

(module+ test
  ;; 默认 none：内容变了，光标字面不动
  (define e0 (editor-open "hello"))
  (define-values (e1 r1) (editor-edit-at e0 0 (point 0 0) (edit-splice (point 0 0) (point 0 0) "XY")))
  (check-equal? (editor-buffer->string e1 0) "XYhello")
  (check-equal? (editor-point e1) (point 0 0))          ; none
  (check-equal? (change-report-first-line r1) 0)
  (check-equal? (change-report-texts r1)
                (list (edit-desc (point 0 0) (point 0 0) "XY")))   ; 施加顺序的生效 desc
  (check-equal? (change-report-attrs r1) '())
  (check-false (editor-can-undo? e1 0))                 ; 默认不记账本

  ;; 'map：光标跟随文本（光标在编辑点之后才会右移）
  (define e0s (editor-set-point e0 (point 0 3)))
  (define-values (e2 _r2) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY") #:reaction 'map))
  (check-equal? (editor-buffer->string e2 0) "hXYello")
  (check-equal? (editor-point e2) (point 0 5))          ; (0,3) 映射到 (0,5)
  ;; 同一场景用 none（不传 #:reaction）：光标字面不动
  (define-values (e2n _r2n) (editor-edit-at e0s 0 (point 0 1) (edit-insert "XY")))
  (check-equal? (editor-point e2n) (point 0 3))

  ;; #:record? #t：记一步，pre-point = 编辑点
  (define-values (e3 _r3) (editor-edit-at e0 0 (point 0 2) (edit-insert "Z") #:record? #t))
  (check-true (editor-can-undo? e3 0))

  ;; #:trusted? #t 跳过 read-only 守卫
  (define-values (tr _trr) (editor-put-attr (editor-open "abc") 0 (point 0 0) (point 0 3) read-only-key #t))
  (define-values (tr1 rtr1) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X)))
  (check-false rtr1)                                    ; 守卫版被拒
  (check-equal? (editor-buffer->string tr1 0) "abc")
  (define-values (tr2 _rtr2) (editor-edit-at tr 0 (point 0 1) (edit-insert-char #\X) #:trusted? #t))
  (check-equal? (editor-buffer->string tr2 0) "aXbc")

  ;; 属性写：只改属性、不碰文本/光标；#:record? #t 才入账本
  (define-values (an _anr) (editor-put-attr (editor-open "hello") 0 (point 0 0) (point 0 5) read-only-key #t #:record? #t))
  (check-true (attr-read-only? (editor-attr-at an 0 (point 0 2))))
  (check-true (editor-can-undo? an 0))

  ;; 文本 + 属性一条命令：插入 "X" 并标只读 —— 一次记一步、report 含文本与属性
  (define cx0 (editor-open "abc"))
  (define-values (cx1 rx)
    (editor-command cx0 (edit-insert "X")
                    #:selection (list (caret (point 0 1)))
                    #:attrs (lambda (_ed _bid texts)
                              (for/list ([d (in-list texts)])
                                (attr-set (edit-desc-start d) (edit-desc-after-position d)
                                          read-only-key #t)))
                    #:reaction 'leader #:record? #t))
  (check-equal? (editor-buffer->string cx1 0) "aXbc")
  (check-equal? (editor-attr-key-runs cx1 0 0 read-only-key) (list (list 1 2 #t)))
  (check-equal? (change-report-texts rx) (list (edit-desc (point 0 1) (point 0 1) "X")))
  (check-equal? (change-report-attrs rx) (list (attr-set (point 0 1) (point 0 2) read-only-key #t)))
  (check-equal? (editor-undo-depth cx1 0) 1)             ; 文本与属性合成一步

  ;; 显式视图命令：按 vid 定位，只动目标 view，不动焦点
  (define v0 (editor-open "l0\nl1\nl2\nl3\nl4" 2 10))
  (define-values (v1 vv) (editor-add-view v0 0 2 10 #:focus? #f))
  (define v2 (editor-view-set-top-line v1 vv 2))
  (check-equal? (editor-view-top-line v2 vv) 2)          ; 目标 view 动了
  (check-equal? (editor-view-top-line v2 0) 0)           ; 另一个 view 不动
  (define v3 (editor-view-set-left-col v2 vv 3))
  (check-equal? (editor-view-left-col v3 vv) 3)
  (define v4 (editor-view-set-mode v3 vv 'wrap))
  (check-equal? (editor-view-mode v4 vv) 'wrap)
  (check-equal? (editor-view-mode v4 0) 'clip)
  (define v5 (editor-view-set-sync v4 vv 'follow))
  (check-equal? (editor-view-sync v5 vv) 'follow)

  ;; wrap 下的折行段：top-seg 可写且被夹紧到合法域
  (define ts0 (editor-open "abcdefghij" 2 3))
  (define ts1 (editor-view-set-mode ts0 0 'wrap))
  (define ts2 (editor-view-set-top-seg ts1 0 1))
  (check-equal? (editor-view-top-seg ts2 0) 1)
  (define-values (v5b other) (editor-open-document v5 "OTHER" 2 10 #:name "other" #:focus? #f))
  (define v6 (editor-view-set-document v5b vv other))
  (check-equal? (editor-view-document-id v6 vv) other)
  (check-equal? (editor-document-id v6) 0)         ; 焦点不动

  ;; focus 糖仍作用于焦点 view
  (define v7 (editor-view-set-point v6 0 (point 1 0)))
  (check-equal? (editor-view-point v7 0) (point 1 0))
  ;; 焦点 view 写糖（与 editor-view-set-* 镜像）
  (define v8 (editor-set-top-line (editor-set-left-col (editor-set-mode v7 'wrap) 2) 1))
  (check-equal? (editor-top-line v8) 1)
  (check-equal? (editor-left-col v8) 2)
  (check-equal? (editor-mode v8) 'wrap)

  ;; 批量：一次施多条，记一步，report.edits 为施加顺序（起点倒序）
  (define b0 (editor-open "abcd\nefgh"))
  (define-values (b1 rb)
    (editor-edit-at-batch b0 0 (list (edit-desc (point 0 1) (point 0 1) "X")
                                     (edit-desc (point 1 2) (point 1 2) "Y"))
                          #:record? #t))
  (check-equal? (editor-buffer->string b1 0) "aXbcd\nefYgh")
  (check-equal? (change-report-texts rb)
                (list (edit-desc (point 1 2) (point 1 2) "Y")
                      (edit-desc (point 0 1) (point 0 1) "X")))
  (check-equal? (editor-undo-depth b1 0) 1)                    ; 整批一步
  (check-equal? (editor-point b1) (point 0 0))                 ; 默认 none：光标不动

  ;; 批量被守卫拒 → 整体没发生；#:trusted? #t 强施
  (define-values (bt _btr) (editor-put-attr (editor-open "abc") 0 (point 0 0) (point 0 3) read-only-key #t))
  (define-values (bt1 rbt1) (editor-edit-at-batch bt 0 (list (edit-desc (point 0 1) (point 0 1) "X"))))
  (check-false rbt1)
  (check-equal? (editor-buffer->string bt1 0) "abc")
  (define-values (bt2 _rbt2) (editor-edit-at-batch bt 0 (list (edit-desc (point 0 1) (point 0 1) "X")) #:trusted? #t))
  (check-equal? (editor-buffer->string bt2 0) "aXbc")

  ;; 加/减选区（并集/差集；primary 保持；不允许空集）
  (define se0 (editor-open "abcdef"))
  (define se1 (editor-add-selections se0 (list (caret (point 0 1)))))
  (check-equal? (length (editor-selections se1)) 2)
  (define se2 (editor-add-selections se1 (list (selection (point 0 3) (point 0 5)))))
  (check-equal? (length (editor-selections se2)) 3)
  (define se3 (editor-remove-selections se2 (list (caret (point 0 1)))))
  (check-equal? (length (editor-selections se3)) 2)
  (check-equal? (length (editor-selections (editor-remove-selections se0 (list (caret (point 0 0)))))) 1)
  ;; 去重：加一个已存在的选区不变多
  (check-equal? (length (editor-selections (editor-add-selections se0 (list (caret (point 0 0)))))) 1)

  ;; primary 控制 + collapse
  (define pr0 (editor-open "abcdef"))
  (define pr1 (editor-set-selections pr0 (list (caret (point 0 0)) (caret (point 0 3))) 1))
  (check-equal? (editor-point pr1) (point 0 3))              ; primary = 传入的第 1 个
  (define pr2 (editor-add-selections pr1 (list (caret (point 0 5))) #:primary? #t))
  (check-equal? (editor-point pr2) (point 0 5))              ; 新加的成为 primary
  (define pr3 (editor-collapse-selections pr2))
  (check-equal? (length (editor-selections pr3)) 1)
  (check-equal? (editor-point pr3) (point 0 5))

  ;; focus 糖：sync / buffer / 重命名
  (define fs0 (editor-open "x"))
  (check-equal? (editor-sync (editor-set-sync fs0 'follow)) 'follow)
  (define-values (fs1 bid2) (editor-open-document fs0 "y" #:name "b" #:focus? #f))
  (define fs2 (editor-set-document fs1 bid2))
  (check-equal? (editor-document-id fs2) bid2)
  (check-equal? (editor-document-name (editor-set-document-name fs2 bid2 "renamed") bid2) "renamed")

  ;; 选区集合算子：显式 primary + map 全部 / map primary + 增删
  (define sm0 (editor-open "abcde"))
  (define sm1 (editor-set-selections sm0 (list (caret (point 0 0)) (caret (point 0 2))) 1))
  (check-equal? (editor-primary sm1) (caret (point 0 2)))
  (check-true (editor-selection-member? sm1 (caret (point 0 0))))
  (define sm2 (editor-map-primary sm1
                (lambda (s) (selection-map-head (lambda (p) (point-right (editor-buffer sm1 0) p)) s))))
  (check-equal? (editor-primary sm2) (selection (point 0 2) (point 0 3)))
  (define sm3 (editor-map-selections sm1
                (lambda (s) (selection-map-both (lambda (p) (point-left (editor-buffer sm1 0) p)) s))))
  (check-equal? (map selection-head (editor-selections sm3)) (list (point 0 0) (point 0 1)))
  (check-equal? (editor-primary (editor-add-selection sm1 (caret (point 0 4)) #:primary? #t)) (caret (point 0 4)))
  (check-equal? (length (editor-selections (editor-remove-selection sm1 (caret (point 0 0))))) 1)
  (check-equal? (editor-primary (editor-set-primary sm1 (caret (point 0 0)))) (caret (point 0 0)))

  ;; 裸写整个 window + 组合：读 window → window-* 算子 → put-window
  (define pw0 (editor-open "abcdef"))
  (define pw1 (editor-put-window pw0 (window-set-point (editor-window pw0) (point 0 3))))
  (check-equal? (editor-point pw1) (point 0 3))
  ;; put-window 只写视图态：document 不符 → 报错（换文档用 editor-view-set-document）
  (check-exn exn:fail? (lambda () (editor-put-window pw0 (window-open (document-open "x") 2 10))))
  ;; map-points：对每个选区 head 施 point→point（坍缩成光标）
  (define pw2 (editor-map-points pw1 (lambda (p) (point 0 (add1 (point-col p))))))
  (check-equal? (editor-point pw2) (point 0 4))
  ;; primary 下标：读 / 写
  (define pv (editor-set-selections pw0 (list (caret (point 0 0)) (caret (point 0 3)))))
  (check-equal? (editor-primary-index pv) 0)
  (check-equal? (editor-primary-index (editor-set-primary-index pv 1)) 1)

  (displayln "program.rkt: all tests passed"))
