#lang racket

(require "base/track.rkt" "base/line.rkt" "base/edit.rkt"
         "base/point.rkt" "base/range.rkt" "base/change.rkt")

;;; document.rkt —— 文档 = 不可变文本 ⊕ 可变属性（高亮 / 只读）
;;;
;;; 底层拆成三个结构体，把不可变 / 可变彻底分开：
;;;
;;;     (struct document-immutable (text))              ; 纯不可变：版本身份
;;;     (struct document-mutable  (highlight readonly)) ; 外壳不可变，内容在 box 里
;;;     (struct document (im mut))                      ; ★ document 本身不可变
;;;
;;; document 的值永不改变：写属性只动 document-mutable 里的 box。
;;; 异步结果（LSP 高亮 / 诊断）写回 = 改句柄，O(1)，不经过 history。
;;;
;;; 两条属性轨语义不变：
;;;     高亮 highlight   每字符一个 face（#f = 无）
;;;     只读 readonly    每字符一个布尔（#t = 不可写）
;;; 三条轨共享同一套行划分（行数一致、每行文本字符数 == 属性格数），document-aligned? 校验。
;;;
;;; **属性轨惰性**：#f = 整轨全默认，不分配属性格；
;;; 文本编辑对全默认封闭（插/删默认格，结果仍全默认），只有属性编辑才 materialize。
;;;
;;; 编辑语义：
;;;     document-edit-tracks       文本编辑：fork 新的 immutable + mutable（属性随编辑搬运）
;;;     document-edit-highlight    只改高亮：**就地**改 box，返回同一个 document
;;;     document-edit-readonly     只改只读：**就地**改 box，返回同一个 document

(provide
 ;; ---------- 类型 ----------
 (struct-out document-immutable)
 (struct-out document-mutable)
 (struct-out document)
 (struct-out clipboard)

 ;; ---------- 构造 ----------
 document-open
 clipboard-of-text

 ;; ---------- 读 / 校验 ----------
 document-text document-highlight document-readonly
 document->string document-range-text document-change-text
 document-highlight-at document-readonly-at?
 document-highlight-row document-readonly-row
 document-highlight-range? document-readonly-range? document-editable?
 document-aligned?

 ;; ---------- 属性原子（写回句柄） ----------
 document-highlight-atom document-readonly-atom
 document-set-highlight! document-set-readonly!

 ;; ---------- 写：文本轨（守只读 / -ignore-readonly） ----------
 document-edit-tracks
 document-insert document-insert-ignore-readonly
 document-delete document-delete-ignore-readonly
 document-replace document-replace-ignore-readonly

 ;; ---------- 写：属性轨 ----------
 document-edit-highlight document-edit-readonly
 document-highlight-fill document-readonly-fill
 document-highlight-fill-batch document-readonly-fill-batch
 document-highlight-fill-range-batch document-readonly-fill-range-batch

 ;; ---------- 剪贴板 ----------
 document-copy document-copy-text
 document-paste document-paste-ignore-readonly)

;;; ---------- 数据 ----------

;; 纯不可变：唯一字段就是文本（版本身份）。
(struct document-immutable (text) #:transparent)
;; text : track（行 = string）

;; 可变部分：外壳不可变，可变性只在两个 box 里。
(struct document-mutable (highlight readonly) #:transparent)
;; highlight : box（行 = vector，格值 = face / #f；或 #f = 整轨全默认）
;; readonly  : box（行 = vector，格值 = #t / #f；或 #f = 整轨全默认）

;; document 本身不可变：只是不可变部分 + 可变部分的不可变对。
(struct document (im mut) #:transparent)

;;; ---------- 读（读穿 box） ----------

(define (document-text bd) (document-immutable-text (document-im bd)))
(define (document-highlight bd) (unbox (document-mutable-highlight (document-mut bd))))
(define (document-readonly bd) (unbox (document-mutable-readonly (document-mut bd))))

;;; ---------- 属性原子：写回句柄 ----------

(define (document-highlight-atom bd) (document-mutable-highlight (document-mut bd)))
(define (document-readonly-atom bd) (document-mutable-readonly (document-mut bd)))

;; 就地写属性：O(1)，不换 document，不碰 history。返回同一个 document 便于串接。
(define (document-set-highlight! bd v)
  (set-box! (document-highlight-atom bd) v)
  bd)
(define (document-set-readonly! bd v)
  (set-box! (document-readonly-atom bd) v)
  bd)

;;; ---------- 构造 ----------

(define (make-document text highlight readonly)
  (document (document-immutable text)
            (document-mutable (box highlight) (box readonly))))

;; 与文本同形、值全为 default 的属性轨。
(define (attr-track-for text default)
  (track-of-list (for/list ([l (in-list (track->list text))])
                   (make-vector (string-length l) default))
                 (track-max text)))

(define (document-open s [chunk-lines default-chunk-lines])
  (make-document (track-of-list (string->lines s) chunk-lines) #f #f))

(define (document->string bd) (lines->string (track->list (document-text bd))))

;;; ---------- 文本编辑：fork 新的 immutable + mutable ----------

;; 属性轨为 #f（全默认）时保持 #f —— 插/删的都是默认格，封闭。
(define (edit-attr a ed) (and a (ed a)))

;; 文本编辑：三条轨一起施同一个编辑，产物是**新的 document**（新 text + 新属性 box）。
;; fork 保证旧版本的属性不被新版本共享（写回旧版本不污染新版本）。
(define (document-edit-tracks bd ed)
  (make-document (ed (document-text bd))
                 (edit-attr (document-highlight bd) ed)
                 (edit-attr (document-readonly bd) ed)))

;;; ---------- 属性编辑：就地改 box ----------

;; 只改高亮 / 只改只读；首次编辑时按当前文本行长 materialize 出真轨。
;; **就地修改**：改 box，返回同一个 document。
(define (document-edit-highlight bd ed)
  (set-box! (document-highlight-atom bd)
            (ed (or (document-highlight bd) (attr-track-for (document-text bd) #f))))
  bd)
(define (document-edit-readonly bd ed)
  (set-box! (document-readonly-atom bd)
            (ed (or (document-readonly bd) (attr-track-for (document-text bd) #f))))
  bd)

;; 赋值糖：把 [l0,c0)..(l1,c1) 的高亮设为 face / 只读设为 flag。
(define (document-highlight-fill bd l0 c0 l1 c1 face)
  (document-edit-highlight bd (edit-fill l0 c0 l1 c1 face)))
(define (document-readonly-fill bd l0 c0 l1 c1 flag)
  (document-edit-readonly bd (edit-fill l0 c0 l1 c1 flag)))

;;; ---------- 批量属性填充（一次 materialize、一次写 box） ----------
;;
;; 坐标版是底层实现；range 版先 range-normalize，再折成坐标走同一条路径。

;; fills : (listof (list l0 c0 l1 c1 val))。本层不规范化坐标。
;; 同一批里重叠处后者覆盖前者；空表 = 不改（返回同一个 document）。
(define (fills->edit fills)
  (lambda (t)
    (for/fold ([t t]) ([f (in-list fills)])
      (match-define (list l0 c0 l1 c1 v) f)
      ((edit-fill l0 c0 l1 c1 v) t))))

(define (document-highlight-fill-batch bd fills)
  (if (null? fills) bd (document-edit-highlight bd (fills->edit fills))))
(define (document-readonly-fill-batch bd fills)
  (if (null? fills) bd (document-edit-readonly bd (fills->edit fills))))

;; 批量（range 版）：runs : (listof (list range val))。range 先规范化，再折成坐标。
(define (ranges->fills runs)
  (for/list ([run (in-list runs)])
    (match-define (list r v) run)
    (define r* (range-normalize r))
    (list (point-line (range-start r*)) (point-col (range-start r*))
          (point-line (range-end r*))   (point-col (range-end r*))
          v)))

(define (document-highlight-fill-range-batch bd runs)
  (document-highlight-fill-batch bd (ranges->fills runs)))
(define (document-readonly-fill-range-batch bd runs)
  (document-readonly-fill-batch bd (ranges->fills runs)))

;;; ---------- 属性查询（高亮 / 只读成对） ----------

;; 高亮 / 只读格：整轨 #f（全默认）→ #f；否则取该格（越界 → #f）。
(define (document-attr-at t line col)
  (and t (let ([l (track-ref t line)]) (and (< col (line-length l)) (line-ref l col)))))

(define (document-highlight-at bd line col)
  (document-attr-at (document-highlight bd) line col))
(define (document-readonly-at? bd line col)
  (document-attr-at (document-readonly bd) line col))

;; 整行属性格（向量视图）：真轨取行；整轨 #f → 按文本行长造全默认向量。
;; 纯读、不改惰性；让"读整行"的调用方不必知道 #f。
(define (document-attr-row a text-line line)
  (if a (track-ref a line) (make-vector (string-length text-line) #f)))

(define (document-highlight-row bd line)
  (document-attr-row (document-highlight bd) (track-ref (document-text bd) line) line))
(define (document-readonly-row bd line)
  (document-attr-row (document-readonly bd) (track-ref (document-text bd) line) line))

;; 区间 [l0,c0)..(l1,c1) 内是否有非默认的属性格。整轨 #f → 无。
(define (document-attr-range? t l0 c0 l1 c1)
  (and t
       (for/or ([i (in-range l0 (add1 l1))])
         (define l (track-ref t i))
         (define a (if (= i l0) c0 0))
         (define b (if (= i l1) c1 (line-length l)))
         (for/or ([j (in-range a b)]) (and (line-ref l j) #t)))))

(define (document-highlight-range? bd l0 c0 l1 c1)
  (document-attr-range? (document-highlight bd) l0 c0 l1 c1))

(define (document-readonly-range? bd l0 c0 l1 c1)
  (document-attr-range? (document-readonly bd) l0 c0 l1 c1))

;;; ---------- 用户编辑 / 程序编辑：成对（守 vs -ignore-readonly） ----------
;;; 约定：**基础名 = 用户编辑（守只读）**；**-ignore-readonly = 程序编辑（不守）**。
;;; 都返回 (values document change ok?)。空编辑（change = #f 且 ok? = #t）不产生新 document。

;; 零宽插入看插入点的格（行尾除外）；非空区间看区间内是否有只读格。
(define (document-readonly-block? bd l0 c0 l1 c1)
  (if (and (= l0 l1) (= c0 c1))
      (let ([len (line-length (track-ref (document-text bd) l0))])
        (and (< c0 len) (document-readonly-at? bd l0 c0)))
      (document-readonly-range? bd l0 c0 l1 c1)))

(define (document-editable? bd l0 c0 l1 c1)
  (not (document-readonly-block? bd l0 c0 l1 c1)))

(define (document-replace* bd l0 c0 l1 c1 text sticky default guard?)
  (cond
    [(and guard? (document-readonly-block? bd l0 c0 l1 c1)) (values bd #f #f)]
    [(and (= l0 l1) (= c0 c1) (string=? text "")) (values bd #f #t)]   ; 空编辑 = 无变更
    [else
     (define sp (span (point l0 c0) (point l1 c1) text))
     (values (document-edit-tracks bd (span->edit sp sticky default))
             (span->change sp)
             #t)]))

(define (document-replace bd l0 c0 l1 c1 text [sticky 'none] [default #f])
  (document-replace* bd l0 c0 l1 c1 text sticky default #t))
(define (document-replace-ignore-readonly bd l0 c0 l1 c1 text [sticky 'none] [default #f])
  (document-replace* bd l0 c0 l1 c1 text sticky default #f))

(define (document-insert bd line col text [sticky 'none] [default #f])
  (document-replace bd line col line col text sticky default))
(define (document-insert-ignore-readonly bd line col text [sticky 'none] [default #f])
  (document-replace-ignore-readonly bd line col line col text sticky default))

(define (document-delete bd l0 c0 l1 c1)
  (document-replace bd l0 c0 l1 c1 ""))
(define (document-delete-ignore-readonly bd l0 c0 l1 c1)
  (document-replace-ignore-readonly bd l0 c0 l1 c1 ""))

;;; ---------- 取文本（按区间） ----------

(define (document-range-text bd r)
  (define r* (range-normalize r))
  (lines->string (range-lines (document-text bd)
                              (point-line (range-start r*)) (point-col (range-start r*))
                              (point-line (range-end r*))   (point-col (range-end r*)))))

;; 取一次变更插入的文本 = 新文档在 change.after 区间上的切片。
(define (document-change-text bd ch)
  (document-range-text bd (change-after ch)))

;;; ---------- 复制 / 粘贴（剪贴板） ----------

;; 从一个文档区间 [l0,c0)..(l1,c1) 抽出某条轨的行片段。
(define (range-lines t l0 c0 l1 c1)
  (define (row i) (track-ref t i))
  (cond
    [(= l0 l1) (list (line-slice (row l0) c0 c1))]
    [else (append (list (line-slice (row l0) c0 (line-length (row l0))))
                  (for/list ([i (in-range (add1 l0) l1)]) (row i))
                  (list (line-slice (row l1) 0 c1)))]))

(struct clipboard (text highlight readonly) #:transparent)
;; text / highlight / readonly : (listof 行片段)，三者同行划分

(define (document-copy bd l0 c0 l1 c1)
  (define text-lines (range-lines (document-text bd) l0 c0 l1 c1))
  (clipboard text-lines
             (attr-lines (document-highlight bd) text-lines l0 c0 l1 c1)
             (attr-lines (document-readonly bd) text-lines l0 c0 l1 c1)))

;; 属性行片段：真轨直接抽；整轨 #f → 按文本片段长度造全默认格。
(define (attr-lines a text-lines l0 c0 l1 c1)
  (if a
      (range-lines a l0 c0 l1 c1)
      (for/list ([tl (in-list text-lines)]) (make-vector (string-length tl) #f))))

;; 只要文本的剪贴板（外部粘贴：高亮/只读全 default）。
(define (document-copy-text bd l0 c0 l1 c1)
  (clipboard-of-text (lines->string (range-lines (document-text bd) l0 c0 l1 c1))))

(define (clipboard-of-text text [hl-default #f] [ro-default #f])
  (define lines (string->lines text))
  (clipboard lines
             (for/list ([l lines]) (make-vector (string-length l) hl-default))
             (for/list ([l lines]) (make-vector (string-length l) ro-default))))

;; 把 clipboard 各轨的行片段拼到目标位置的某条轨上（按 payload 类型自动分派）。
(define (splice-clipboard-lines t line col pieces)
  (define l0 (track-ref t line))
  (define head (line-slice l0 0 col))
  (define tail (line-slice l0 col (line-length l0)))
  (define k (length pieces))
  (define new-lines
    (cond
      [(= k 1) (list (line-append (line-append head (car pieces)) tail))]
      [else (append (list (line-append head (car pieces)))
                    (drop-right (rest pieces) 1)
                    (list (line-append (last pieces) tail)))]))
  (track-splice t line (add1 line) new-lines))

;; 粘贴是文本编辑：产出**新 document**（新 text + 新属性 box）。
(define (document-paste* bd line col cp guard?)
  (define text (lines->string (clipboard-text cp)))
  (cond
    [(and guard? (document-readonly-block? bd line col line col)) (values bd #f #f)]
    [(string=? text "") (values bd #f #t)]                            ; 空剪贴板 = 无变更
    [else
     (values (make-document
              (splice-clipboard-lines (document-text bd) line col (clipboard-text cp))
              (paste-attr (document-highlight bd) (document-text bd) line col (clipboard-highlight cp))
              (paste-attr (document-readonly bd) (document-text bd) line col (clipboard-readonly cp)))
             (span->change (span (point line col) (point line col) text))
             #t)]))

;; 目标属性轨为 #f：剪贴板片段也全默认 → 保持 #f；否则 materialize 再拼。
(define (pieces-default? pieces)
  (for/and ([p (in-list pieces)])
    (for/and ([v (in-vector p)]) (not v))))

(define (paste-attr a text line col pieces)
  (cond
    [a (splice-clipboard-lines a line col pieces)]
    [(pieces-default? pieces) #f]
    [else (splice-clipboard-lines (attr-track-for text #f) line col pieces)]))

(define (document-paste bd line col cp)
  (document-paste* bd line col cp #t))
(define (document-paste-ignore-readonly bd line col cp)
  (document-paste* bd line col cp #f))

;;; ---------- 校验 ----------

(define (document-aligned? bd)
  (define rows (track->list (document-text bd)))
  (define (ok? t)
    (or (not t)
        (let ([arows (track->list t)])
          (and (= (length rows) (length arows))
               (for/and ([l rows] [a arows]) (= (string-length l) (line-length a)))))))
  (and (ok? (document-highlight bd)) (ok? (document-readonly bd))))
