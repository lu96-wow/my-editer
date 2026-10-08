#lang racket

(require "base/track.rkt" "base/line.rkt" "base/edit.rkt"
         "base/point.rkt" "base/range.rkt" "base/change.rkt"
         "slots.rkt")

;;; document.rkt —— 文档 = 不可变文本 ⊕ 端口（face / readonly）⊕ 开放槽
;;;
;;; 拆成三个结构体，把"不可变 / 固定端口 / 开放槽"彻底分开：
;;;
;;;     (struct document-immutable (text))                 ; 纯不可变：版本身份
;;;     (struct document-mutable  (face readonly slots))   ; 外壳不可变，内容在 box / slots 里
;;;     (struct document (im mut))                         ; ★ document 本身不可变
;;;
;;; 端口（port）：core 的固定契约。core 的固定行为依赖它们，语义固定、名字固定：
;;;     face      每字符一个 face（#f = 无）      —— 渲染读
;;;     readonly  每字符一个布尔（#t = 不可写）   —— 编辑守读
;;; 每个端口一个 box；就地改、O(1)、不换 document。
;;;
;;; 槽（slot）：特性声明的 opaque 存储，收在 slots 结构体里（见 slots.rkt）。core 只管理
;;; 生命周期 / fork，从不读槽内容。
;;;
;;; document 的值永不改变：写端口 / 槽只动 box。异步结果写回 = 改句柄，O(1)，不经过 history。
;;;
;;; 惰性：#f = 整轨全默认，不分配属性格；文本编辑对全默认封闭，只有属性编辑才 materialize。
;;;
;;; 编辑语义：
;;;     document-edit-tracks    文本编辑：fork 新 immutable + mutable（端口按编辑搬运，槽走 fork 计划）
;;;     document-edit-face      只改 face：**就地**改 box
;;;     document-edit-readonly  只改 readonly：**就地**改 box
;;;     document-edit-slot      只改某槽：**就地**改 box

(provide
 ;; ---------- 类型 ----------
 (struct-out document-immutable)
 (struct-out document-mutable)
 (struct-out document)

 ;; ---------- 构造 ----------
 document-open

 ;; ---------- 读 / 校验 ----------
 document-text document-slots document-face document-readonly
 document->string document-range-text document-change-text
 document-slot-ref document-face-at document-readonly-at?
 document-face-row document-readonly-row
 document-face-range? document-readonly-range? document-editable?
 document-aligned?

 ;; ---------- 原子（写回句柄） ----------
 document-slot-atom document-slot-set!
 document-face-atom document-readonly-atom
 document-set-face! document-set-readonly!

 ;; ---------- 写：文本轨（守只读 / -ignore-readonly） ----------
 document-edit-tracks
 document-insert document-insert-ignore-readonly
 document-delete document-delete-ignore-readonly
 document-replace document-replace-ignore-readonly

 ;; ---------- 写：端口（固定轨 API） ----------
 document-edit-face document-edit-readonly
 document-face-fill document-readonly-fill
 document-face-fill-batch document-readonly-fill-batch
 document-face-fill-batch*
 document-face-fill-range-batch document-readonly-fill-range-batch

 ;; ---------- 写：槽（opaque 值 API） ----------
 document-slot-set! document-edit-slot

 ;; ---------- 复制（纯文本） ----------
 document-copy)

;;; ---------- 数据 ----------

;; 纯不可变：唯一字段就是文本（版本身份）。
(struct document-immutable (text) #:transparent)
;; text : track（行 = string）

;; 可变部分：外壳不可变，可变性只在 box / slots 里。
(struct document-mutable (face readonly slots) #:transparent)
;; face     : box（行 = vector，格值 = face / #f；或 #f = 整轨全默认）
;; readonly : box（行 = vector，格值 = #t / #f；或 #f = 整轨全默认）
;; slots    : slots 结构体（开放槽容器，见 slots.rkt）

;; document 本身不可变：只是不可变部分 + 可变部分的不可变对。
(struct document (im mut) #:transparent)

;;; ---------- 读（读穿 box） ----------

(define (document-text bd) (document-immutable-text (document-im bd)))
(define (document-slots bd) (document-mutable-slots (document-mut bd)))
(define (document-face bd) (unbox (document-mutable-face (document-mut bd))))
(define (document-readonly bd) (unbox (document-mutable-readonly (document-mut bd))))

;;; ---------- 端口原子：写回句柄 ----------

(define (document-face-atom bd) (document-mutable-face (document-mut bd)))
(define (document-readonly-atom bd) (document-mutable-readonly (document-mut bd)))

;; 就地写端口：O(1)，不换 document，不碰 history。返回同一个 document 便于串接。
(define (document-set-face! bd v) (set-box! (document-face-atom bd) v) bd)
(define (document-set-readonly! bd v) (set-box! (document-readonly-atom bd) v) bd)

;;; ---------- 槽通用访问（按 index） ----------
;; document 不认识槽名；命名访问器由 slot-dsl.rkt 的宏生成。

(define (document-slot-ref bd sl) (slot-ref (document-slots bd) sl))
(define (document-slot-atom bd sl) (slot-atom (document-slots bd) sl))
(define (document-slot-set! bd sl v) (slot-set! (document-slots bd) sl v) bd)

;; 就地读改写（纯值变换，不假设轨形）。
(define (document-edit-slot bd sl f)
  (document-slot-set! bd sl (f (document-slot-ref bd sl))))

;;; ---------- 构造 ----------

(define (make-document* text face readonly slots)
  (document (document-immutable text)
            (document-mutable face readonly slots)))

;; 与文本同形、值全为 default 的属性轨。
(define (attr-track-for text default)
  (track-of-list (for/list ([l (in-list (track->list text))])
                   (make-vector (string-length l) default))
                 (track-max text)))

(define (document-open s [chunk-lines default-chunk-lines])
  (freeze-slots!)                                   ; 槽注册必须早于任何文档创建
  (make-document* (track-of-list (string->lines s) chunk-lines)
                  (box #f) (box #f) (make-slots)))

(define (document->string bd) (lines->string (track->list (document-text bd))))

;;; ---------- 文本编辑：fork 新的 immutable + mutable ----------

;; 属性轨为 #f（全默认）时保持 #f —— 插/删的都是默认格，封闭。
(define (edit-attr a ed) (and a (ed a)))

;; 文本编辑：端口按编辑搬运，槽走 fork 计划；产物是**新的 document**。
;; 每格装新 box → 旧版本的端口 / 槽不被新版本共享。
(define (document-edit-tracks bd ed [changes '()])
  (define old (document-text bd))
  (define new (ed old))
  (make-document* new
                  (box (edit-attr (document-face bd) ed))
                  (box (edit-attr (document-readonly bd) ed))
                  (fork-slots (document-slots bd) (fork-ctx ed changes old new))))

;;; ---------- 端口：就地改 box（固定轨语义） ----------
;; port-of : document -> box。首次编辑时按当前文本行长 materialize 出真轨。

(define (port-edit bd port-of ed)
  (set-box! (port-of bd)
            (ed (or (unbox (port-of bd)) (attr-track-for (document-text bd) #f))))
  bd)

(define (port-fill bd port-of l0 c0 l1 c1 val)
  (port-edit bd port-of (edit-fill l0 c0 l1 c1 val)))

(define (port-fill-batch bd port-of fills)
  (if (null? fills) bd (port-edit bd port-of (fills->edit fills))))
(define (port-fill-batch* bd port-of fills combine)
  (if (null? fills) bd (port-edit bd port-of (fills->edit* fills combine))))
(define (port-fill-range-batch bd port-of runs)
  (port-fill-batch bd port-of (ranges->fills runs)))

;;; ---------- 端口：命名包装 ----------

(define (document-edit-face bd ed) (port-edit bd document-face-atom ed))
(define (document-edit-readonly bd ed) (port-edit bd document-readonly-atom ed))

(define (document-face-fill bd l0 c0 l1 c1 face) (port-fill bd document-face-atom l0 c0 l1 c1 face))
(define (document-readonly-fill bd l0 c0 l1 c1 flag) (port-fill bd document-readonly-atom l0 c0 l1 c1 flag))

(define (document-face-fill-batch bd fills) (port-fill-batch bd document-face-atom fills))
(define (document-face-fill-batch* bd fills combine)
  (port-fill-batch* bd document-face-atom fills combine))
(define (document-readonly-fill-batch bd fills) (port-fill-batch bd document-readonly-atom fills))

(define (document-face-fill-range-batch bd runs) (port-fill-range-batch bd document-face-atom runs))
(define (document-readonly-fill-range-batch bd runs)
  (port-fill-range-batch bd document-readonly-atom runs))

;;; ---------- 槽：无轨假设（opaque 值） ----------
;; 轨型槽的读 / 写由特性自己在值上做（用 base/edit 的 edit-* 变换），core 不提供。

;;; ---------- 批量填充的底层（坐标版） ----------
;;
;; fills : (listof (list l0 c0 l1 c1 val))。本层不规范化坐标。
;; 同一批里重叠处后者覆盖前者；空表 = 不改（返回同一个 document）。
(define (fills->edit fills)
  (lambda (t)
    (for/fold ([t t]) ([f (in-list fills)])
      (match-define (list l0 c0 l1 c1 v) f)
      ((edit-fill l0 c0 l1 c1 v) t))))

;; 组合版：combine : 旧格 新值 -> 新格。每格不直接覆盖，而是与已有值合成（分层外观）。
(define (fills->edit* fills combine)
  (lambda (t)
    (for/fold ([t t]) ([f (in-list fills)])
      (match-define (list l0 c0 l1 c1 v) f)
      ((edit-fill* l0 c0 l1 c1 v combine) t))))

;; 批量（range 版）：runs : (listof (list range val))。range 先规范化，再折成坐标。
(define (ranges->fills runs)
  (for/list ([run (in-list runs)])
    (match-define (list r v) run)
    (define r* (range-normalize r))
    (list (point-line (range-start r*)) (point-column (range-start r*))
          (point-line (range-end r*))   (point-column (range-end r*))
          v)))

;;; ---------- 查询（端口） ----------

;; 格：整轨 #f（全默认）→ #f；否则取该格（越界 → #f）。
(define (document-attr-at t line col)
  (and t (let ([l (track-ref t line)]) (and (< col (line-length l)) (line-ref l col)))))

;; 整行属性格（向量视图）：真轨取行；整轨 #f → 按文本行长造全默认向量。
;; 纯读、不改惰性；让"读整行"的调用方不必知道 #f。
(define (document-attr-row a text-line line)
  (if a (track-ref a line) (make-vector (string-length text-line) #f)))

;; 区间 [l0,c0)..(l1,c1) 内是否有非默认的属性格。整轨 #f → 无。
(define (document-attr-range? t l0 c0 l1 c1)
  (and t
       (for/or ([i (in-range l0 (add1 l1))])
         (define l (track-ref t i))
         (define a (if (= i l0) c0 0))
         (define b (if (= i l1) c1 (line-length l)))
         (for/or ([j (in-range a b)]) (and (line-ref l j) #t)))))

;; 端口
(define (document-face-at bd line col) (document-attr-at (document-face bd) line col))
(define (document-readonly-at? bd line col) (document-attr-at (document-readonly bd) line col))
(define (document-face-row bd line)
  (document-attr-row (document-face bd) (track-ref (document-text bd) line) line))
(define (document-readonly-row bd line)
  (document-attr-row (document-readonly bd) (track-ref (document-text bd) line) line))
(define (document-face-range? bd l0 c0 l1 c1) (document-attr-range? (document-face bd) l0 c0 l1 c1))
(define (document-readonly-range? bd l0 c0 l1 c1)
  (document-attr-range? (document-readonly bd) l0 c0 l1 c1))


;;; ---------- 用户编辑 / 程序编辑：成对（守 vs -ignore-readonly） ----------
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
     (define ch (span->change sp))
     (values (document-edit-tracks bd (span->edit sp sticky default) (list ch))
             ch
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
                              (point-line (range-start r*)) (point-column (range-start r*))
                              (point-line (range-end r*))   (point-column (range-end r*)))))

;; 取一次变更插入的文本 = 新文档在 change.after 区间上的切片。
(define (document-change-text bd ch)
  (document-range-text bd (change-after ch)))

;;; ---------- 区间取行 / 复制 ----------

;; 从一个文档区间 [l0,c0)..(l1,c1) 抽出某条轨的行片段。
(define (range-lines t l0 c0 l1 c1)
  (define (row i) (track-ref t i))
  (cond
    [(= l0 l1) (list (line-slice (row l0) c0 c1))]
    [else (append (list (line-slice (row l0) c0 (line-length (row l0))))
                  (for/list ([i (in-range (add1 l0) l1)]) (row i))
                  (list (line-slice (row l1) 0 c1)))]))

;; 复制 = 取纯文本（属性不随剪贴板走；粘贴 = 普通文本插入，走 fork 计划）。
(define (document-copy bd l0 c0 l1 c1)
  (document-range-text bd (range-of (point l0 c0) (point l1 c1))))

;;; ---------- 校验 ----------

;; 只校验 core 端口（槽的轨形由特性自己负责）。
(define (document-aligned? bd)
  (define rows (track->list (document-text bd)))
  (define (ok? t)
    (or (not t)
        (let ([arows (track->list t)])
          (and (= (length rows) (length arows))
               (for/and ([l rows] [a arows]) (= (string-length l) (line-length a)))))))
  (and (ok? (document-face bd)) (ok? (document-readonly bd))))
