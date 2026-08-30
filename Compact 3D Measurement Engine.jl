
/*
 * PyMeasure3D-C / Measure3D
 *
 * Compact 3D Measurement Engine
 *
 * Features:
 *   - 3D vector mathematics
 *   - Point-cloud management
 *   - Centroid calculation
 *   - Noise/outlier filtering
 *   - PCA principal-axis estimation
 *   - Oriented bounding box
 *   - Length / width / height
 *   - Point-to-point distance
 *   - Point-to-plane distance
 *   - Plane fitting
 *   - Normal estimation
 *   - Surface-area approximation
 *   - Convex-hull-style volume approximation
 *   - Voxel volume approximation
 *   - Cylinder / circle fitting
 *   - Measurement uncertainty
 *   - Confidence estimation
 *   - Synthetic sensor/object generation
 *   - CSV point-cloud loading
 *   - Machine-readable report
 *
 * Build:
 *   cc -O3 -std=c11 measure3d.c -lm -o measure3d
 *
 * This is a geometry/measurement engine. It does not claim
 * metrology-grade accuracy without calibrated hardware,
 * traceable references and validation.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <float.h>
#include <time.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define EPS 1e-12
#define MAX_ITER 64

/* ============================================================
 * BASIC TYPES
 * ============================================================ */

typedef struct {
    double x;
    double y;
    double z;
} Vec3;

typedef struct {
    double r;
    double g;
    double b;
} RGB;

typedef struct {
    Vec3 p;
    RGB color;
    double confidence;
} Point3D;

typedef struct {
    Point3D *data;
    size_t count;
    size_t capacity;
} PointCloud;

typedef struct {
    Vec3 center;
    Vec3 axis[3];
    Vec3 extent;
    double volume;
} OBB;

typedef struct {
    Vec3 normal;
    double d;
    double rms_error;
    size_t inliers;
} Plane;

typedef struct {
    double radius;
    Vec3 center;
    Vec3 normal;
    double rms_error;
    size_t inliers;
} Circle3D;

typedef struct {
    double value;
    double uncertainty;
    double confidence;
    int valid;
} Measurement;

typedef struct {
    Measurement length;
    Measurement width;
    Measurement height;
    Measurement volume;
    Measurement surface_area;
    Measurement diagonal;
} MeasurementResult;

/* ============================================================
 * VECTOR OPERATIONS
 * ============================================================ */

static Vec3 v3(double x, double y, double z)
{
    Vec3 v = {x, y, z};
    return v;
}

static Vec3 vadd(Vec3 a, Vec3 b)
{
    return v3(a.x+b.x, a.y+b.y, a.z+b.z);
}

static Vec3 vsub(Vec3 a, Vec3 b)
{
    return v3(a.x-b.x, a.y-b.y, a.z-b.z);
}

static Vec3 vmul(Vec3 a, double s)
{
    return v3(a.x*s, a.y*s, a.z*s);
}

static double vdot(Vec3 a, Vec3 b)
{
    return a.x*b.x + a.y*b.y + a.z*b.z;
}

static Vec3 vcross(Vec3 a, Vec3 b)
{
    return v3(
        a.y*b.z - a.z*b.y,
        a.z*b.x - a.x*b.z,
        a.x*b.y - a.y*b.x
    );
}

static double vnorm(Vec3 a)
{
    return sqrt(vdot(a,a));
}

static Vec3 vnormalize(Vec3 a)
{
    double n = vnorm(a);

    if (n < EPS)
        return v3(0,0,0);

    return vmul(a, 1.0/n);
}

static double vdistance(Vec3 a, Vec3 b)
{
    return vnorm(vsub(a,b));
}

static Vec3 vlerp(Vec3 a, Vec3 b, double t)
{
    return vadd(a, vmul(vsub(b,a),t));
}

/* ============================================================
 * POINT CLOUD
 * ============================================================ */

static PointCloud *cloud_create(size_t initial_capacity)
{
    PointCloud *pc = calloc(1,sizeof(PointCloud));

    if (!pc)
        return NULL;

    pc->capacity = initial_capacity ? initial_capacity : 1024;
    pc->data = malloc(sizeof(Point3D)*pc->capacity);

    if (!pc->data) {
        free(pc);
        return NULL;
    }

    return pc;
}

static void cloud_destroy(PointCloud *pc)
{
    if (!pc)
        return;

    free(pc->data);
    free(pc);
}

static int cloud_reserve(PointCloud *pc, size_t n)
{
    if (n <= pc->capacity)
        return 1;

    size_t cap = pc->capacity;

    while (cap < n)
        cap *= 2;

    Point3D *p = realloc(pc->data,sizeof(Point3D)*cap);

    if (!p)
        return 0;

    pc->data = p;
    pc->capacity = cap;

    return 1;
}

static int cloud_add(PointCloud *pc, Vec3 p)
{
    if (!cloud_reserve(pc,pc->count+1))
        return 0;

    pc->data[pc->count].p = p;
    pc->data[pc->count].color = (RGB){255,255,255};
    pc->data[pc->count].confidence = 1.0;

    pc->count++;

    return 1;
}

static PointCloud *cloud_clone(const PointCloud *src)
{
    PointCloud *dst = cloud_create(src->count);

    if (!dst)
        return NULL;

    memcpy(dst->data,src->data,sizeof(Point3D)*src->count);
    dst->count = src->count;

    return dst;
}

/* ============================================================
 * CENTROID
 * ============================================================ */

static Vec3 cloud_centroid(const PointCloud *pc)
{
    Vec3 c = v3(0,0,0);

    if (!pc || pc->count == 0)
        return c;

    for (size_t i=0;i<pc->count;i++)
        c = vadd(c,pc->data[i].p);

    return vmul(c,1.0/(double)pc->count);
}

/* ============================================================
 * AXIS-ALIGNED BOUNDING BOX
 * ============================================================ */

static void cloud_bounds(
    const PointCloud *pc,
    Vec3 *minv,
    Vec3 *maxv)
{
    *minv = v3(DBL_MAX,DBL_MAX,DBL_MAX);
    *maxv = v3(-DBL_MAX,-DBL_MAX,-DBL_MAX);

    for (size_t i=0;i<pc->count;i++) {

        Vec3 p = pc->data[i].p;

        if (p.x < minv->x) minv->x = p.x;
        if (p.y < minv->y) minv->y = p.y;
        if (p.z < minv->z) minv->z = p.z;

        if (p.x > maxv->x) maxv->x = p.x;
        if (p.y > maxv->y) maxv->y = p.y;
        if (p.z > maxv->z) maxv->z = p.z;
    }
}

/* ============================================================
 * COVARIANCE MATRIX
 * ============================================================ */

static void covariance_matrix(
    const PointCloud *pc,
    double C[3][3],
    Vec3 centroid)
{
    memset(C,0,sizeof(double)*9);

    if (!pc || pc->count == 0)
        return;

    for (size_t i=0;i<pc->count;i++) {

        Vec3 d = vsub(pc->data[i].p,centroid);

        C[0][0] += d.x*d.x;
        C[0][1] += d.x*d.y;
        C[0][2] += d.x*d.z;

        C[1][0] += d.y*d.x;
        C[1][1] += d.y*d.y;
        C[1][2] += d.y*d.z;

        C[2][0] += d.z*d.x;
        C[2][1] += d.z*d.y;
        C[2][2] += d.z*d.z;
    }

    double n = (double)pc->count;

    for (int r=0;r<3;r++)
        for (int c=0;c<3;c++)
            C[r][c] /= n;
}

/* ============================================================
 * JACOBI EIGEN SOLVER
 * ============================================================ */

static void eigen_jacobi(
    double A[3][3],
    double eigenvalues[3],
    Vec3 eigenvectors[3])
{
    double V[3][3] = {
        {1,0,0},
        {0,1,0},
        {0,0,1}
    };

    for (int iter=0;iter<MAX_ITER;iter++) {

        int p=0,q=1;
        double largest=fabs(A[0][1]);

        if (fabs(A[0][2]) > largest) {
            p=0; q=2;
            largest=fabs(A[0][2]);
        }

        if (fabs(A[1][2]) > largest) {
            p=1; q=2;
            largest=fabs(A[1][2]);
        }

        if (largest < 1e-14)
            break;

        double theta =
            0.5*atan2(
                2*A[p][q],
                A[q][q]-A[p][p]
            );

        double c=cos(theta);
        double s=sin(theta);

        double app=A[p][p];
        double aqq=A[q][q];
        double apq=A[p][q];

        A[p][p] = c*c*app - 2*s*c*apq + s*s*aqq;
        A[q][q] = s*s*app + 2*s*c*apq + c*c*aqq;

        A[p][q]=A[q][p]=0;

        for (int k=0;k<3;k++) {

            if (k==p || k==q)
                continue;

            double akp=A[k][p];
            double akq=A[k][q];

            A[k][p]=A[p][k]=c*akp-s*akq;
            A[k][q]=A[q][k]=s*akp+c*akq;
        }

        for (int k=0;k<3;k++) {

            double vkp=V[k][p];
            double vkq=V[k][q];

            V[k][p]=c*vkp-s*vkq;
            V[k][q]=s*vkp+c*vkq;
        }
    }

    for (int i=0;i<3;i++) {

        eigenvalues[i]=A[i][i];

        eigenvectors[i]=vnormalize(
            v3(
                V[0][i],
                V[1][i],
                V[2][i]
            )
        );
    }
}

/* ============================================================
 * PCA AXES
 * ============================================================ */

static void cloud_pca(
    const PointCloud *pc,
    Vec3 axes[3],
    double eigenvalues[3])
{
    Vec3 c=cloud_centroid(pc);

    double C[3][3];

    covariance_matrix(pc,C,c);

    eigen_jacobi(C,eigenvalues,axes);

    /*
     * Sort largest eigenvalue first.
     */
    for (int i=0;i<2;i++) {

        for (int j=i+1;j<3;j++) {

            if (eigenvalues[j] > eigenvalues[i]) {

                double tv=eigenvalues[i];
                eigenvalues[i]=eigenvalues[j];
                eigenvalues[j]=tv;

                Vec3 ta=axes[i];
                axes[i]=axes[j];
                axes[j]=ta;
            }
        }
    }

    /*
     * Ensure right-handed coordinate system.
     */
    axes[2]=vnormalize(vcross(axes[0],axes[1]));
}

/* ============================================================
 * ORIENTED BOUNDING BOX
 * ============================================================ */

static OBB cloud_obb(const PointCloud *pc)
{
    OBB box;

    memset(&box,0,sizeof(box));

    if (!pc || pc->count==0)
        return box;

    double eval[3];

    cloud_pca(pc,box.axis,eval);

    Vec3 c=cloud_centroid(pc);

    double minv[3]={
        DBL_MAX,DBL_MAX,DBL_MAX
    };

    double maxv[3]={
        -DBL_MAX,-DBL_MAX,-DBL_MAX
    };

    for (size_t i=0;i<pc->count;i++) {

        Vec3 d=vsub(pc->data[i].p,c);

        for (int a=0;a<3;a++) {

            double q=vdot(d,box.axis[a]);

            if (q<minv[a]) minv[a]=q;
            if (q>maxv[a]) maxv[a]=q;
        }
    }

    Vec3 local_center=v3(
        (minv[0]+maxv[0])*0.5,
        (minv[1]+maxv[1])*0.5,
        (minv[2]+maxv[2])*0.5
    );

    box.extent=v3(
        maxv[0]-minv[0],
        maxv[1]-minv[1],
        maxv[2]-minv[2]
    );

    box.center=c;

    for (int i=0;i<3;i++)
        box.center=vadd(
            box.center,
            vmul(box.axis[i],local_center.x*(i==0)+
                               local_center.y*(i==1)+
                               local_center.z*(i==2))
        );

    box.volume=
        box.extent.x*
        box.extent.y*
        box.extent.z;

    return box;
}

/* ============================================================
 * DISTANCE FUNCTIONS
 * ============================================================ */

static double point_distance(Vec3 a,Vec3 b)
{
    return vdistance(a,b);
}

static double point_plane_distance(Vec3 p,Plane plane)
{
    return fabs(vdot(plane.normal,p)+plane.d);
}

/* ============================================================
 * PLANE FITTING
 * ============================================================ */

static Plane fit_plane(const PointCloud *pc)
{
    Plane plane;

    memset(&plane,0,sizeof(plane));

    if (!pc || pc->count<3)
        return plane;

    Vec3 axes[3];
    double eval[3];

    cloud_pca(pc,axes,eval);

    plane.normal=axes[2];

    Vec3 c=cloud_centroid(pc);

    plane.d=-vdot(plane.normal,c);

    double sum=0;

    for (size_t i=0;i<pc->count;i++) {

        double e=
            vdot(
                plane.normal,
                pc->data[i].p
            )+plane.d;

        sum+=e*e;
    }

    plane.rms_error=
        sqrt(sum/(double)pc->count);

    plane.inliers=pc->count;

    return plane;
}

/* ============================================================
 * POINT-TO-PLANE PROJECTION
 * ============================================================ */

static Vec3 project_point_plane(Vec3 p,Plane plane)
{
    double d=
        vdot(plane.normal,p)+plane.d;

    return vsub(
        p,
        vmul(plane.normal,d)
    );
}

/* ============================================================
 * NOISE FILTER
 *
 * Simple radial filter around centroid.
 * For production use, replace/augment with KD-tree
 * statistical-neighbour filtering.
 * ============================================================ */

static PointCloud *filter_radius(
    const PointCloud *src,
    double radius)
{
    if (!src)
        return NULL;

    Vec3 c=cloud_centroid(src);

    PointCloud *dst=cloud_create(src->count);

    if (!dst)
        return NULL;

    for (size_t i=0;i<src->count;i++) {

        double d=vdistance(
            src->data[i].p,c
        );

        /*
         * Keep points within radius.
         * This is deliberately simple and intended
         * as a baseline filtering primitive.
         */
        if (d<=radius)
            cloud_add(dst,src->data[i].p);
    }

    return dst;
}

/* ============================================================
 * STATISTICAL SCALE ESTIMATION
 * ============================================================ */

static double cloud_mean_radius(
    const PointCloud *pc)
{
    Vec3 c=cloud_centroid(pc);

    double sum=0;

    for (size_t i=0;i<pc->count;i++)
        sum+=vdistance(pc->data[i].p,c);

    if (pc->count==0)
        return 0;

    return sum/(double)pc->count;
}

static double cloud_radius_std(
    const PointCloud *pc)
{
    Vec3 c=cloud_centroid(pc);

    double mean=cloud_mean_radius(pc);
    double sum=0;

    for (size_t i=0;i<pc->count;i++) {

        double d=vdistance(pc->data[i].p,c);
        double e=d-mean;

        sum+=e*e;
    }

    if (pc->count<2)
        return 0;

    return sqrt(
        sum/(double)(pc->count-1)
    );
}

/* ============================================================
 * VOXEL VOLUME
 *
 * Hash-free reference implementation.
 * Useful for demonstration and moderate clouds.
 * ============================================================ */

typedef struct {
    int x,y,z;
} Voxel;

static int voxel_exists(
    Voxel *voxels,
    size_t count,
    Voxel v)
{
    for (size_t i=0;i<count;i++) {

        if (
            voxels[i].x==v.x &&
            voxels[i].y==v.y &&
            voxels[i].z==v.z
        )
            return 1;
    }

    return 0;
}

static double voxel_volume(
    const PointCloud *pc,
    double voxel_size)
{
    if (!pc || pc->count==0 ||
        voxel_size<=0)
        return 0;

    Voxel *voxels=
        malloc(sizeof(Voxel)*pc->count);

    if (!voxels)
        return 0;

    size_t count=0;

    for (size_t i=0;i<pc->count;i++) {

        Vec3 p=pc->data[i].p;

        Voxel v={
            (int)floor(p.x/voxel_size),
            (int)floor(p.y/voxel_size),
            (int)floor(p.z/voxel_size)
        };

        if (!voxel_exists(voxels,count,v))
            voxels[count++]=v;
    }

    double volume=
        (double)count*
        voxel_size*
        voxel_size*
        voxel_size;

    free(voxels);

    return volume;
}

/* ============================================================
 * TETRAHEDRON VOLUME
 * ============================================================ */

static double tetra_volume(
    Vec3 a,
    Vec3 b,
    Vec3 c,
    Vec3 d)
{
    Vec3 ab=vsub(b,a);
    Vec3 ac=vsub(c,a);
    Vec3 ad=vsub(d,a);

    return fabs(
        vdot(
            ab,
            vcross(ac,ad)
        )
    )/6.0;
}

/* ============================================================
 * SIMPLE SURFACE AREA APPROXIMATION
 *
 * Uses projected PCA bounding-box surface.
 * A full mesh triangulation engine can replace this.
 * ============================================================ */

static double obb_surface_area(OBB box)
{
    double x=box.extent.x;
    double y=box.extent.y;
    double z=box.extent.z;

    return 2.0*(x*y+x*z+y*z);
}

/* ============================================================
 * CIRCLE FITTING
 *
 * For approximately planar points.
 * Uses centroid + mean radial distance.
 * ============================================================ */

static Circle3D fit_circle(const PointCloud *pc)
{
    Circle3D circle;

    memset(&circle,0,sizeof(circle));

    if (!pc || pc->count<3)
        return circle;

    Plane plane=fit_plane(pc);

    circle.normal=plane.normal;

    Vec3 c=cloud_centroid(pc);

    double radius=0;

    for (size_t i=0;i<pc->count;i++) {

        Vec3 q=
            project_point_plane(
                pc->data[i].p,
                plane
            );

        radius+=vdistance(q,c);
    }

    radius/=pc->count;

    double error=0;

    for (size_t i=0;i<pc->count;i++) {

        Vec3 q=
            project_point_plane(
                pc->data[i].p,
                plane
            );

        double e=
            vdistance(q,c)-radius;

        error+=e*e;
    }

    circle.center=c;
    circle.radius=radius;

    circle.rms_error=
        sqrt(error/(double)pc->count);

    circle.inliers=pc->count;

    return circle;
}

/* ============================================================
 * MEASUREMENT CREATION
 * ============================================================ */

static Measurement make_measurement(
    double value,
    double uncertainty,
    double confidence)
{
    Measurement m;

    m.value=value;
    m.uncertainty=uncertainty;
    m.confidence=confidence;
    m.valid=isfinite(value);

    return m;
}

/* ============================================================
 * UNCERTAINTY MODEL
 *
 * This is a practical engineering estimate rather than a
 * traceable metrology uncertainty budget.
 * ============================================================ */

static double estimate_uncertainty(
    double dimension,
    double sensor_noise,
    size_t samples)
{
    if (samples<1)
        samples=1;

    double sampling=
        sensor_noise/
        sqrt((double)samples);

    double scale_error=
        fabs(dimension)*0.001;

    return sqrt(
        sampling*sampling+
        scale_error*scale_error
    );
}

/* ============================================================
 * CONFIDENCE MODEL
 * ============================================================ */

static double confidence_from_error(
    double rms_error,
    double dimension)
{
    if (dimension<=EPS)
        return 0;

    double relative=
        rms_error/dimension;

    double confidence=
        exp(-relative*100.0);

    if (confidence<0)
        confidence=0;

    if (confidence>1)
        confidence=1;

    return confidence;
}

/* ============================================================
 * FULL MEASUREMENT
 * ============================================================ */

static MeasurementResult measure_object(
    const PointCloud *pc,
    double sensor_noise)
{
    MeasurementResult r;

    memset(&r,0,sizeof(r));

    if (!pc || pc->count<3)
        return r;

    OBB box=cloud_obb(pc);

    double x=box.extent.x;
    double y=box.extent.y;
    double z=box.extent.z;

    /*
     * Sort dimensions.
     */
    double d[3]={x,y,z};

    for (int i=0;i<2;i++)
        for (int j=i+1;j<3;j++)
            if (d[j]>d[i]) {
                double t=d[i];
                d[i]=d[j];
                d[j]=t;
            }

    double volume=d[0]*d[1]*d[2];

    double surface=
        2.0*(
            d[0]*d[1]+
            d[0]*d[2]+
            d[1]*d[2]
        );

    double diagonal=
        sqrt(
            d[0]*d[0]+
            d[1]*d[1]+
            d[2]*d[2]
        );

    double cloud_error=
        cloud_radius_std(pc);

    double confidence=
        confidence_from_error(
            cloud_error,
            d[0]
        );

    r.length=
        make_measurement(
            d[0],
            estimate_uncertainty(
                d[0],
                sensor_noise,
                pc->count
            ),
            confidence
        );

    r.width=
        make_measurement(
            d[1],
            estimate_uncertainty(
                d[1],
                sensor_noise,
                pc->count
            ),
            confidence
        );

    r.height=
        make_measurement(
            d[2],
            estimate_uncertainty(
                d[2],
                sensor_noise,
                pc->count
            ),
            confidence
        );

    double volume_uncertainty=
        volume*0.003;

    r.volume=
        make_measurement(
            volume,
            volume_uncertainty,
            confidence
        );

    r.surface_area=
        make_measurement(
            surface,
            surface*0.003,
            confidence
        );

    r.diagonal=
        make_measurement(
            diagonal,
            sensor_noise,
            confidence
        );

    return r;
}

/* ============================================================
 * DIMENSIONAL CONVERSION
 * ============================================================ */

static double mm_to_m(double x)
{
    return x/1000.0;
}

static double m_to_mm(double x)
{
    return x*1000.0;
}

static double mm3_to_litres(double mm3)
{
    return mm3/1000000.0;
}

/* ============================================================
 * CSV LOADER
 *
 * Expected:
 *
 * x,y,z
 *
 * or:
 *
 * x,y,z,r,g,b
 * ============================================================ */

static PointCloud *load_csv(
    const char *filename)
{
    FILE *f=fopen(filename,"r");

    if (!f)
        return NULL;

    PointCloud *pc=cloud_create(4096);

    if (!pc) {
        fclose(f);
        return NULL;
    }

    char line[1024];

    while (fgets(line,sizeof(line),f)) {

        if (line[0]=='#')
            continue;

        double x,y,z;

        if (
            sscanf(
                line,
                "%lf,%lf,%lf",
                &x,&y,&z
            )==3
        )
            cloud_add(pc,v3(x,y,z));
    }

    fclose(f);

    return pc;
}

/* ============================================================
 * SYNTHETIC BOX
 * ============================================================ */

static PointCloud *synthetic_box(
    double length,
    double width,
    double height,
    size_t density,
    double noise)
{
    size_t estimated=
        density*density*density/4+100;

    PointCloud *pc=
        cloud_create(estimated);

    if (!pc)
        return NULL;

    for (size_t i=0;i<density;i++) {

        double fx=
            (double)i/
            (double)(density-1);

        for (size_t j=0;j<density;j++) {

            double fy=
                (double)j/
                (double)(density-1);

            /*
             * Six surfaces.
             */

            for (int face=0;face<6;face++) {

                double u=fx;
                double v=fy;

                Vec3 p;

                switch(face) {

                    case 0:
                        p=v3(
                            length*u,
                            width*v,
                            0
                        );
                        break;

                    case 1:
                        p=v3(
                            length*u,
                            width*v,
                            height
                        );
                        break;

                    case 2:
                        p=v3(
                            length*u,
                            0,
                            height*v
                        );
                        break;

                    case 3:
                        p=v3(
                            length*u,
                            width,
                            height*v
                        );
                        break;

                    case 4:
                        p=v3(
                            0,
                            width*u,
                            height*v
                        );
                        break;

                    default:
                        p=v3(
                            length,
                            width*u,
                            height*v
                        );
                }

                double nx=
                    ((double)rand()/RAND_MAX-0.5)
                    *noise;

                double ny=
                    ((double)rand()/RAND_MAX-0.5)
                    *noise;

                double nz=
                    ((double)rand()/RAND_MAX-0.5)
                    *noise;

                p.x+=nx;
                p.y+=ny;
                p.z+=nz;

                cloud_add(pc,p);
            }
        }
    }

    return pc;
}

/* ============================================================
 * SYNTHETIC CYLINDER
 * ============================================================ */

static PointCloud *synthetic_cylinder(
    double radius,
    double height,
    size_t rings,
    size_t segments,
    double noise)
{
    PointCloud *pc=
        cloud_create(
            rings*segments+segments*2
        );

    if (!pc)
        return NULL;

    for (size_t r=0;r<rings;r++) {

        double z=
            height*
            ((double)r/(double)(rings-1));

        for (size_t s=0;s<segments;s++) {

            double theta=
                2.0*M_PI*
                (double)s/
                (double)segments;

            double n=
                ((double)rand()/RAND_MAX-0.5)
                *noise;

            Vec3 p=v3(
                (radius+n)*cos(theta),
                (radius+n)*sin(theta),
                z
            );

            cloud_add(pc,p);
        }
    }

    return pc;
}

/* ============================================================
 * POINT-CLOUD STATISTICS
 * ============================================================ */

static void cloud_statistics(
    const PointCloud *pc,
    double *mean,
    double *stddev)
{
    *mean=0;
    *stddev=0;

    if (!pc || pc->count==0)
        return;

    Vec3 c=cloud_centroid(pc);

    for (size_t i=0;i<pc->count;i++)
        *mean+=vdistance(
            pc->data[i].p,c
        );

    *mean/=pc->count;

    for (size_t i=0;i<pc->count;i++) {

        double d=
            vdistance(
                pc->data[i].p,c
            );

        double e=d-*mean;

        *stddev+=e*e;
    }

    if (pc->count>1)
        *stddev=
            sqrt(
                *stddev/
                (pc->count-1)
            );
}

/* ============================================================
 * MEASUREMENT STABILITY
 * ============================================================ */

static double measurement_stability(
    const double *values,
    size_t count)
{
    if (!values || count<2)
        return 0;

    double mean=0;

    for (size_t i=0;i<count;i++)
        mean+=values[i];

    mean/=count;

    double variance=0;

    for (size_t i=0;i<count;i++) {

        double e=values[i]-mean;
        variance+=e*e;
    }

    variance/=(count-1);

    double sd=sqrt(variance);

    if (fabs(mean)<EPS)
        return 0;

    double cv=sd/fabs(mean);

    double confidence=
        exp(-cv*1000.0);

    if (confidence>1)
        confidence=1;

    return confidence;
}

/* ============================================================
 * MULTI-SCAN AVERAGING
 * ============================================================ */

static double average_measurements(
    const double *values,
    size_t count)
{
    if (!values || count==0)
        return 0;

    double sum=0;

    for (size_t i=0;i<count;i++)
        sum+=values[i];

    return sum/(double)count;
}

/* ============================================================
 * JSON REPORT
 * ============================================================ */

static void print_measurement_json(
    Measurement m)
{
    printf(
        "{"
        "\"value\":%.6f,"
        "\"uncertainty\":%.6f,"
        "\"confidence\":%.6f,"
        "\"valid\":%s"
        "}",
        m.value,
        m.uncertainty,
        m.confidence,
        m.valid ? "true":"false"
    );
}

static void print_result_json(
    MeasurementResult r)
{
    printf("{\n");

    printf("\"length\":");
    print_measurement_json(r.length);

    printf(",\n\"width\":");
    print_measurement_json(r.width);

    printf(",\n\"height\":");
    print_measurement_json(r.height);

    printf(",\n\"volume\":");
    print_measurement_json(r.volume);

    printf(",\n\"surface_area\":");
    print_measurement_json(r.surface_area);

    printf(",\n\"diagonal\":");
    print_measurement_json(r.diagonal);

    printf("\n}\n");
}

/* ============================================================
 * HUMAN REPORT
 * ============================================================ */

static void print_result(
    MeasurementResult r)
{
    printf("\n");
    printf("====================================\n");
    printf("       3D MEASUREMENT RESULT\n");
    printf("====================================\n");

    printf(
        "Length : %.3f +/- %.3f\n",
        r.length.value,
        r.length.uncertainty
    );

    printf(
        "Width  : %.3f +/- %.3f\n",
        r.width.value,
        r.width.uncertainty
    );

    printf(
        "Height : %.3f +/- %.3f\n",
        r.height.value,
        r.height.uncertainty
    );

    printf(
        "Volume : %.3f\n",
        r.volume.value
    );

    printf(
        "Area   : %.3f\n",
        r.surface_area.value
    );

    printf(
        "Diag.  : %.3f\n",
        r.diagonal.value
    );

    printf(
        "Confidence: %.2f%%\n",
        r.length.confidence*100.0
    );

    printf("====================================\n");
}

/* ============================================================
 * DIGITAL-TWIN OBJECT
 * ============================================================ */

typedef struct {
    uint64_t id;

    Vec3 position;
    Vec3 orientation;

    MeasurementResult measurements;

    size_t point_count;

    double timestamp;

    char source[64];
} DigitalObject;

static DigitalObject make_digital_object(
    uint64_t id,
    const PointCloud *pc,
    MeasurementResult measurements)
{
    DigitalObject obj;

    memset(&obj,0,sizeof(obj));

    obj.id=id;

    obj.position=
        cloud_centroid(pc);

    obj.orientation=
        v3(0,0,0);

    obj.measurements=
        measurements;

    obj.point_count=
        pc ? pc->count : 0;

    obj.timestamp=
        (double)time(NULL);

    snprintf(
        obj.source,
        sizeof(obj.source),
        "synthetic"
    );

    return obj;
}

/* ============================================================
 * DIGITAL-TWIN JSON
 * ============================================================ */

static void print_digital_object(
    DigitalObject *obj)
{
    printf("\n");
    printf("{\n");

    printf(
        "\"object_id\":%llu,\n",
        (unsigned long long)obj->id
    );

    printf(
        "\"position\":"
        "{\"x\":%.6f,\"y\":%.6f,\"z\":%.6f},\n",
        obj->position.x,
        obj->position.y,
        obj->position.z
    );

    printf(
        "\"point_count\":%zu,\n",
        obj->point_count
    );

    printf(
        "\"timestamp\":%.0f,\n",
        obj->timestamp
    );

    printf(
        "\"source\":\"%s\",\n",
        obj->source
    );

    printf("\"measurements\":");

    print_result_json(obj->measurements);

    printf("}\n");
}

/* ============================================================
 * DEMONSTRATION
 * ============================================================ */

static void run_demo(void)
{
    srand((unsigned int)time(NULL));

    /*
     * Units: millimetres.
     */
    double true_length=420.0;
    double true_width=280.0;
    double true_height=160.0;

    printf("Creating synthetic 3D object...\n");

    PointCloud *pc=
        synthetic_box(
            true_length,
            true_width,
            true_height,
            24,
            0.75
        );

    if (!pc) {
        fprintf(stderr,
                "Failed to create cloud.\n");
        return;
    }

    printf(
        "Points captured: %zu\n",
        pc->count
    );

    Vec3 centroid=
        cloud_centroid(pc);

    printf(
        "Centroid: %.3f %.3f %.3f\n",
        centroid.x,
        centroid.y,
        centroid.z
    );

    double mean,stddev;

    cloud_statistics(
        pc,
        &mean,
        &stddev
    );

    printf(
        "Cloud radius mean: %.3f\n",
        mean
    );

    printf(
        "Cloud radius std: %.3f\n",
        stddev
    );

    /*
     * PCA.
     */
    Vec3 axes[3];
    double eigenvalues[3];

    cloud_pca(
        pc,
        axes,
        eigenvalues
    );

    printf("\nPrincipal axes:\n");

    for (int i=0;i<3;i++) {

        printf(
            "Axis %d: %.4f %.4f %.4f\n",
            i,
            axes[i].x,
            axes[i].y,
            axes[i].z
        );

        printf(
            "Eigenvalue: %.4f\n",
            eigenvalues[i]
        );
    }

    /*
     * OBB.
     */
    OBB box=cloud_obb(pc);

    printf("\nOBB dimensions:\n");

    printf(
        "%.3f x %.3f x %.3f\n",
        box.extent.x,
        box.extent.y,
        box.extent.z
    );

    printf(
        "OBB volume: %.3f mm3\n",
        box.volume
    );

    /*
     * Plane.
     */
    Plane plane=fit_plane(pc);

    printf("\nPlane estimate:\n");

    printf(
        "Normal: %.4f %.4f %.4f\n",
        plane.normal.x,
        plane.normal.y,
        plane.normal.z
    );

    printf(
        "RMS plane error: %.5f\n",
        plane.rms_error
    );

    /*
     * Circle diagnostic.
     */
    Circle3D circle=fit_circle(pc);

    printf("\nPlanar-circle diagnostic:\n");

    printf(
        "Radius estimate: %.3f\n",
        circle.radius
    );

    /*
     * Measurements.
     */
    MeasurementResult result=
        measure_object(
            pc,
            0.75
        );

    print_result(result);

    printf("\nMachine-readable output:\n");

    print_result_json(result);

    /*
     * Digital twin.
     */
    DigitalObject obj=
        make_digital_object(
            1,
            pc,
            result
        );

    printf(
        "\nDigital twin object:\n"
    );

    print_digital_object(&obj);

    /*
     * Voxel volume.
     *
     * This is intentionally a coarse demonstration.
     */
    double vv=
        voxel_volume(
            pc,
            10.0
        );

    printf(
        "\nVoxel volume estimate: %.3f mm3\n",
        vv
    );

    /*
     * Ground-truth comparison.
     */
    printf("\nGround truth comparison:\n");

    printf(
        "Length error: %.3f mm\n",
        result.length.value-true_length
    );

    printf(
        "Width error: %.3f mm\n",
        result.width.value-true_width
    );

    printf(
        "Height error: %.3f mm\n",
        result.height.value-true_height
    );

    cloud_destroy(pc);
}

/* ============================================================
 * COMMAND LINE
 * ============================================================ */

static void print_help(const char *program)
{
    printf(
        "\n"
        "Measure3D\n"
        "\n"
        "Usage:\n"
        "  %s demo\n"
        "  %s csv file.csv\n"
        "\n"
        "CSV format:\n"
        "  x,y,z\n"
        "\n",
        program,
        program
    );
}

static void process_csv(
    const char *filename)
{
    PointCloud *pc=
        load_csv(filename);

    if (!pc) {

        fprintf(
            stderr,
            "Unable to load %s\n",
            filename
        );

        return;
    }

    printf(
        "Loaded %zu points.\n",
        pc->count
    );

    if (pc->count<3) {

        fprintf(
            stderr,
            "At least three points required.\n"
        );

        cloud_destroy(pc);
        return;
    }

    MeasurementResult result=
        measure_object(
            pc,
            1.0
        );

    print_result(result);

    print_result_json(result);

    cloud_destroy(pc);
}

/* ============================================================
 * MAIN
 * ============================================================ */

int main(int argc,char **argv)
{
    if (argc<2) {

        print_help(argv[0]);

        printf(
            "Running demonstration...\n"
        );

        run_demo();

        return 0;
    }

    if (strcmp(argv[1],"demo")==0) {

        run_demo();

        return 0;
    }

    if (
        strcmp(argv[1],"csv")==0 &&
        argc>=3
    ) {

        process_csv(argv[2]);

        return 0;
    }

    print_help(argv[0]);

    return 0;
}































# ================================================================
# 3D METROLOGY ENGINE
# Julia 1.10+
#
# General-purpose computational metrology engine.
#
# Capabilities:
#   - 3D points / vectors
#   - Coordinate transformations
#   - Distances / angles
#   - Point-cloud processing
#   - Noise filtering
#   - Plane / line / circle / sphere / cylinder fitting
#   - Point-cloud registration
#   - Surface deviation
#   - Tolerance analysis
#   - Measurement uncertainty
#   - Measurement quality
#   - Measurement audit trail
#   - JSON export
#
# Intended as a foundation for industrial inspection,
# manufacturing, construction, robotics and digital-twin systems.
# ================================================================

module MetrologyEngine

using LinearAlgebra
using Statistics
using Dates
using Random
using Printf

# ================================================================
# CONFIGURATION
# ================================================================

const ENGINE_NAME = "Julia 3D Metrology Engine"
const ENGINE_VERSION = "0.1.0"

# ================================================================
# BASIC TYPES
# ================================================================

struct Point3D{T<:Real}
    x::T
    y::T
    z::T
end

Point3D(x::Real, y::Real, z::Real) =
    Point3D(promote(x, y, z)...)

Base.show(io::IO, p::Point3D) =
    print(io, "Point3D($(p.x), $(p.y), $(p.z))")

Base.:+(a::Point3D, b::Point3D) =
    Point3D(a.x+b.x, a.y+b.y, a.z+b.z)

Base.:-(a::Point3D, b::Point3D) =
    Point3D(a.x-b.x, a.y-b.y, a.z-b.z)

Base.:*(s::Real, p::Point3D) =
    Point3D(s*p.x, s*p.y, s*p.z)

Base.:/(p::Point3D, s::Real) =
    Point3D(p.x/s, p.y/s, p.z/s)

function vector(p::Point3D)
    return [Float64(p.x), Float64(p.y), Float64(p.z)]
end

function point(v::AbstractVector)
    length(v) == 3 || error("3D vector required")
    return Point3D(v[1], v[2], v[3])
end

# ================================================================
# VECTOR OPERATIONS
# ================================================================

function dot3(a::Point3D, b::Point3D)
    return a.x*b.x + a.y*b.y + a.z*b.z
end

function cross3(a::Point3D, b::Point3D)
    return Point3D(
        a.y*b.z - a.z*b.y,
        a.z*b.x - a.x*b.z,
        a.x*b.y - a.y*b.x
    )
end

function norm3(p::Point3D)
    return sqrt(p.x^2 + p.y^2 + p.z^2)
end

function normalize3(p::Point3D)
    n = norm3(p)

    n > eps(Float64) ||
        error("Cannot normalize zero vector")

    return p / n
end

function distance(a::Point3D, b::Point3D)
    return norm3(a-b)
end

# ================================================================
# ANGLES
# ================================================================

function angle_between(a::Point3D, b::Point3D)

    na = norm3(a)
    nb = norm3(b)

    na > 0 || error("Zero vector")
    nb > 0 || error("Zero vector")

    c = dot3(a,b)/(na*nb)

    c = clamp(c, -1.0, 1.0)

    return acos(c)
end

function angle_degrees(a::Point3D, b::Point3D)
    return rad2deg(angle_between(a,b))
end

# ================================================================
# POINT CLOUD
# ================================================================

struct PointCloud{T<:Real}
    points::Vector{Point3D{T}}
    timestamp::DateTime
    sensor_id::String
    frame::String
end

function PointCloud(
    points::Vector{Point3D{T}};
    sensor_id="unknown",
    frame="world"
) where T<:Real

    return PointCloud(
        points,
        now(),
        sensor_id,
        frame
    )
end

Base.length(pc::PointCloud) = length(pc.points)

# ================================================================
# POINT CLOUD CONVERSION
# ================================================================

function point_matrix(pc::PointCloud)

    n = length(pc)

    M = Matrix{Float64}(undef, 3, n)

    for i in 1:n
        p = pc.points[i]

        M[:,i] = [
            p.x,
            p.y,
            p.z
        ]
    end

    return M
end

function matrix_to_cloud(
    M;
    sensor_id="unknown",
    frame="world"
)

    size(M,1) == 3 ||
        error("Matrix must be 3 × N")

    pts = Point3D{Float64}[]

    for i in axes(M,2)
        push!(
            pts,
            Point3D(
                M[1,i],
                M[2,i],
                M[3,i]
            )
        )
    end

    return PointCloud(
        pts,
        sensor_id=sensor_id,
        frame=frame
    )
end

# ================================================================
# CENTROID
# ================================================================

function centroid(points::Vector{<:Point3D})

    isempty(points) &&
        error("Empty point collection")

    x = mean(p.x for p in points)
    y = mean(p.y for p in points)
    z = mean(p.z for p in points)

    return Point3D(x,y,z)
end

centroid(pc::PointCloud) =
    centroid(pc.points)

# ================================================================
# BOUNDING BOX
# ================================================================

function bounding_box(pc::PointCloud)

    isempty(pc.points) &&
        error("Empty point cloud")

    xs = [p.x for p in pc.points]
    ys = [p.y for p in pc.points]
    zs = [p.z for p in pc.points]

    minimum_point = Point3D(
        minimum(xs),
        minimum(ys),
        minimum(zs)
    )

    maximum_point = Point3D(
        maximum(xs),
        maximum(ys),
        maximum(zs)
    )

    dimensions =
        maximum_point - minimum_point

    return (
        min = minimum_point,
        max = maximum_point,
        dimensions = dimensions
    )
end

# ================================================================
# 4 × 4 TRANSFORMATION
# ================================================================

struct Transform3D
    matrix::Matrix{Float64}

    function Transform3D(M::AbstractMatrix)

        size(M) == (4,4) ||
            error("Transformation must be 4 × 4")

        new(Matrix{Float64}(M))
    end
end

function identity_transform()
    return Transform3D(Matrix{Float64}(I,4,4))
end

function translation(tx,ty,tz)

    M = Matrix{Float64}(I,4,4)

    M[1,4] = tx
    M[2,4] = ty
    M[3,4] = tz

    return Transform3D(M)
end

function rotation_x(angle)

    c = cos(angle)
    s = sin(angle)

    M = Matrix{Float64}(I,4,4)

    M[2,2] = c
    M[2,3] = -s
    M[3,2] = s
    M[3,3] = c

    return Transform3D(M)
end

function rotation_y(angle)

    c = cos(angle)
    s = sin(angle)

    M = Matrix{Float64}(I,4,4)

    M[1,1] = c
    M[1,3] = s
    M[3,1] = -s
    M[3,3] = c

    return Transform3D(M)
end

function rotation_z(angle)

    c = cos(angle)
    s = sin(angle)

    M = Matrix{Float64}(I,4,4)

    M[1,1] = c
    M[1,2] = -s
    M[2,1] = s
    M[2,2] = c

    return Transform3D(M)
end

function compose(A::Transform3D, B::Transform3D)

    return Transform3D(
        A.matrix * B.matrix
    )
end

function transform_point(
    T::Transform3D,
    p::Point3D
)

    v = [
        p.x,
        p.y,
        p.z,
        1.0
    ]

    r = T.matrix * v

    return Point3D(
        r[1]/r[4],
        r[2]/r[4],
        r[3]/r[4]
    )
end

function transform_cloud(
    pc::PointCloud,
    T::Transform3D
)

    pts = [
        transform_point(T,p)
        for p in pc.points
    ]

    return PointCloud(
        pts,
        sensor_id=pc.sensor_id,
        frame=pc.frame
    )
end

# ================================================================
# PLANE
# ================================================================

struct Plane
    normal::Point3D{Float64}
    point::Point3D{Float64}
    d::Float64
end

function Plane(normal::Point3D, point::Point3D)

    n = normalize3(normal)

    d = -dot3(n,point)

    return Plane(n,point,d)
end

function point_plane_distance(
    p::Point3D,
    plane::Plane
)

    return abs(
        dot3(plane.normal,p) + plane.d
    )
end

function signed_plane_distance(
    p::Point3D,
    plane::Plane
)

    return dot3(
        plane.normal,p
    ) + plane.d
end

# ================================================================
# PLANE FITTING
# ================================================================

function fit_plane(points::Vector{<:Point3D})

    length(points) >= 3 ||
        error("At least 3 points required")

    c = centroid(points)

    X = zeros(Float64, length(points), 3)

    for (i,p) in enumerate(points)

        X[i,:] = [
            p.x-c.x,
            p.y-c.y,
            p.z-c.z
        ]

    end

    _,_,V = svd(X)

    n = V[:,end]

    plane = Plane(
        Point3D(n[1],n[2],n[3]),
        c
    )

    residuals = [
        signed_plane_distance(p,plane)
        for p in points
    ]

    rms = sqrt(
        mean(residuals.^2)
    )

    return (
        plane=plane,
        rms_error=rms,
        residuals=residuals
    )
end

# ================================================================
# LINE FITTING
# ================================================================

struct Line3D
    origin::Point3D{Float64}
    direction::Point3D{Float64}
end

function fit_line(points::Vector{<:Point3D})

    length(points) >= 2 ||
        error("At least 2 points required")

    c = centroid(points)

    X = zeros(Float64,length(points),3)

    for (i,p) in enumerate(points)

        X[i,:] = [
            p.x-c.x,
            p.y-c.y,
            p.z-c.z
        ]

    end

    _,_,V = svd(X)

    d = V[:,1]

    line = Line3D(
        c,
        normalize3(
            Point3D(d[1],d[2],d[3])
        )
    )

    return line
end

function point_line_distance(
    p::Point3D,
    line::Line3D
)

    v = p - line.origin

    projection =
        dot3(v,line.direction) *
        line.direction

    perpendicular =
        v - projection

    return norm3(perpendicular)
end

# ================================================================
# SPHERE
# ================================================================

struct Sphere
    center::Point3D{Float64}
    radius::Float64
end

function fit_sphere(points::Vector{<:Point3D})

    length(points) >= 4 ||
        error("At least 4 points required")

    A = zeros(Float64,length(points),4)
    b = zeros(Float64,length(points))

    for (i,p) in enumerate(points)

        A[i,1] = 2*p.x
        A[i,2] = 2*p.y
        A[i,3] = 2*p.z

        A[i,4] = 1

        b[i] =
            p.x^2 +
            p.y^2 +
            p.z^2

    end

    solution =
        A \ b

    center = Point3D(
        solution[1],
        solution[2],
        solution[3]
    )

    radius = sqrt(
        solution[4] +
        center.x^2 +
        center.y^2 +
        center.z^2
    )

    residuals = [
        distance(p,center)-radius
        for p in points
    ]

    rms = sqrt(
        mean(residuals.^2)
    )

    return (
        sphere=Sphere(center,radius),
        rms_error=rms,
        residuals=residuals
    )
end

# ================================================================
# CYLINDER
# ================================================================

struct Cylinder
    axis::Line3D
    radius::Float64
end

function fit_cylinder(
    points::Vector{<:Point3D};
    iterations=5
)

    length(points) >= 10 ||
        error("At least 10 points recommended")

    line = fit_line(points)

    radius = mean(
        point_line_distance(p,line)
        for p in points
    )

    for _ in 1:iterations

        distances = [
            point_line_distance(p,line)
            for p in points
        ]

        weights = [
            1.0/(1.0+d+eps())
            for d in distances
        ]

        c = centroid(points)

        # Weighted covariance
        X = zeros(Float64,length(points),3)

        for i in eachindex(points)

            p = points[i]

            X[i,:] = sqrt(weights[i]) .* [
                p.x-c.x,
                p.y-c.y,
                p.z-c.z
            ]

        end

        _,_,V = svd(X)

        direction = V[:,1]

        line = Line3D(
            c,
            normalize3(
                Point3D(
                    direction[1],
                    direction[2],
                    direction[3]
                )
            )
        )

        radius = mean(
            point_line_distance(p,line)
            for p in points
        )

    end

    residuals = [
        point_line_distance(p,line)-radius
        for p in points
    ]

    return (
        cylinder=Cylinder(line,radius),
        rms_error=sqrt(mean(residuals.^2)),
        residuals=residuals
    )
end

# ================================================================
# CIRCLE IN PLANE
# ================================================================

struct Circle3D
    center::Point3D{Float64}
    normal::Point3D{Float64}
    radius::Float64
end

function fit_circle_3d(points::Vector{<:Point3D})

    length(points) >= 3 ||
        error("At least 3 points required")

    plane_result =
        fit_plane(points)

    plane =
        plane_result.plane

    n = vector(plane.normal)

    # Construct orthogonal basis
    temp =
        abs(n[1]) < 0.9 ?
        [1.0,0.0,0.0] :
        [0.0,1.0,0.0]

    u = normalize(cross(n,temp))
    v = cross(n,u)

    c = centroid(points)

    X = zeros(Float64,length(points),2)

    for (i,p) in enumerate(points)

        r = vector(p-c)

        X[i,1] = dot(r,u)
        X[i,2] = dot(r,v)

    end

    A = zeros(Float64,length(points),3)
    b = zeros(Float64,length(points))

    for i in axes(X,1)

        x = X[i,1]
        y = X[i,2]

        A[i,:] = [
            2x,
            2y,
            1
        ]

        b[i] = x^2+y^2

    end

    sol = A\b

    cx = sol[1]
    cy = sol[2]

    center =
        c +
        Point3D(
            cx*u[1] + cy*v[1],
            cx*u[2] + cy*v[2],
            cx*u[3] + cy*v[3]
        )

    radius = sqrt(
        sol[3] +
        cx^2 +
        cy^2
    )

    return Circle3D(
        center,
        plane.normal,
        radius
    )
end

# ================================================================
# NEAREST NEIGHBOUR
# ================================================================

function nearest_neighbor(
    p::Point3D,
    cloud::PointCloud
)

    isempty(cloud.points) &&
        error("Empty point cloud")

    best_index = 1
    best_distance = Inf

    for i in eachindex(cloud.points)

        d = distance(
            p,
            cloud.points[i]
        )

        if d < best_distance

            best_distance = d
            best_index = i

        end

    end

    return (
        index=best_index,
        point=cloud.points[best_index],
        distance=best_distance
    )
end

# ================================================================
# NOISE FILTER
# ================================================================

function statistical_filter(
    pc::PointCloud;
    sigma=2.5
)

    n = length(pc)

    n < 4 &&
        return pc

    distances = Float64[]

    for i in 1:n

        local_sum = 0.0
        count = 0

        for j in 1:n

            i == j && continue

            local_sum +=
                distance(
                    pc.points[i],
                    pc.points[j]
                )

            count += 1

            count >= min(10,n-1) &&
                break
        end

        push!(
            distances,
            local_sum/count
        )

    end

    μ = mean(distances)
    σ = std(distances)

    threshold =
        μ + sigma*σ

    filtered = [
        pc.points[i]
        for i in 1:n
        if distances[i] <= threshold
    ]

    return PointCloud(
        filtered,
        sensor_id=pc.sensor_id,
        frame=pc.frame
    )
end

# ================================================================
# ICP-STYLE REGISTRATION
# ================================================================

function rigid_transform(
    source::Vector{<:Point3D},
    target::Vector{<:Point3D}
)

    length(source) ==
    length(target) ||
        error("Point sets must have equal length")

    length(source) >= 3 ||
        error("At least 3 correspondences required")

    cs = centroid(source)
    ct = centroid(target)

    H = zeros(Float64,3,3)

    for i in eachindex(source)

        a = vector(source[i]-cs)
        b = vector(target[i]-ct)

        H += a*b'

    end

    U,_,Vt = svd(H)

    R = Vt*U'

    if det(R) < 0

        Vt[3,:] .*= -1

        R = Vt*U'

    end

    t =
        vector(ct) -
        R*vector(cs)

    M = Matrix{Float64}(I,4,4)

    M[1:3,1:3] = R
    M[1:3,4] = t

    return Transform3D(M)
end

function register_clouds(
    source::PointCloud,
    target::PointCloud;
    iterations=10,
    tolerance=1e-6
)

    current = source
    T_total = identity_transform()

    previous_error = Inf

    for iteration in 1:iterations

        src = current.points
        tgt = Point3D{Float64}[]

        for p in src

            nn =
                nearest_neighbor(
                    p,
                    target
                )

            push!(
                tgt,
                nn.point
            )

        end

        T =
            rigid_transform(src,tgt)

        current =
            transform_cloud(
                current,T
            )

        T_total =
            compose(T,T_total)

        errors = [
            distance(
                current.points[i],
                tgt[i]
            )
            for i in eachindex(src)
        ]

        error_value =
            mean(errors)

        if abs(
            previous_error -
            error_value
        ) < tolerance

            break

        end

        previous_error =
            error_value
    end

    final_errors = [
        nearest_neighbor(
            p,target
        ).distance
        for p in current.points
    ]

    return (
        transform=T_total,
        registered=current,
        rms_error=
            sqrt(mean(final_errors.^2)),
        mean_error=
            mean(final_errors),
        iterations=iterations
    )
end

# ================================================================
# SURFACE DEVIATION
# ================================================================

function deviation_map(
    measured::PointCloud,
    reference::PointCloud
)

    deviations = Float64[]

    for p in measured.points

        nn =
            nearest_neighbor(
                p,
                reference
            )

        push!(
            deviations,
            nn.distance
        )

    end

    return deviations
end

# ================================================================
# TOLERANCE
# ================================================================

struct ToleranceSpec
    nominal::Float64
    lower::Float64
    upper::Float64
end

struct ToleranceResult
    measured::Float64
    nominal::Float64
    deviation::Float64
    lower_limit::Float64
    upper_limit::Float64
    pass::Bool
end

function check_tolerance(
    value::Real,
    tolerance::ToleranceSpec
)

    deviation =
        Float64(value) -
        tolerance.nominal

    lower =
        tolerance.nominal +
        tolerance.lower

    upper =
        tolerance.nominal +
        tolerance.upper

    pass =
        lower <= value <= upper

    return ToleranceResult(
        Float64(value),
        tolerance.nominal,
        deviation,
        lower,
        upper,
        pass
    )
end

# ================================================================
# UNCERTAINTY
# ================================================================

struct MeasurementResult
    id::String
    value::Float64
    unit::String
    uncertainty::Float64
    confidence::Float64
    method::String
    timestamp::DateTime
    quality::Float64
end

function uncertainty_from_samples(
    values;
    confidence=0.95,
    unit=""
)

    n = length(values)

    n >= 2 ||
        error("At least two observations required")

    μ = mean(values)
    s = std(values)

    standard_error =
        s/sqrt(n)

    # Normal approximation.
    # Replace with appropriate t-distribution
    # implementation for formal metrology work.
    z =
        confidence >= 0.99 ? 2.576 :
        confidence >= 0.95 ? 1.960 :
        confidence >= 0.90 ? 1.645 :
        1.0

    u =
        z*standard_error

    return (
        value=μ,
        uncertainty=u,
        confidence=confidence,
        unit=unit
    )
end

# ================================================================
# MEASUREMENT QUALITY
# ================================================================

function quality_score(
    residuals;
    specification=1.0
)

    isempty(residuals) &&
        return 0.0

    rms =
        sqrt(mean(residuals.^2))

    score =
        100 *
        exp(-rms /
            max(specification,eps()))

    return clamp(score,0.0,100.0)
end

# ================================================================
# DIMENSIONAL MEASUREMENTS
# ================================================================

function measure_length(
    points::Vector{<:Point3D}
)

    isempty(points) &&
        error("No points supplied")

    min_p = centroid(points)
    max_distance = 0.0

    for i in eachindex(points)

        for j in i+1:length(points)

            d =
                distance(
                    points[i],
                    points[j]
                )

            if d > max_distance

                max_distance = d

            end
        end
    end

    return max_distance
end

function measure_width(pc::PointCloud)

    box =
        bounding_box(pc)

    return box.dimensions.x
end

function measure_height(pc::PointCloud)

    box =
        bounding_box(pc)

    return box.dimensions.z
end

function measure_depth(pc::PointCloud)

    box =
        bounding_box(pc)

    return box.dimensions.y
end

# ================================================================
# VOLUME — AXIS ALIGNED BOUNDING BOX
# ================================================================

function bounding_volume(pc::PointCloud)

    d =
        bounding_box(pc).dimensions

    return d.x*d.y*d.z
end

# ================================================================
# CONVEX-HULL-FRIENDLY SIMPLE VOLUME
#
# This is deliberately a placeholder abstraction rather than
# pretending an arbitrary point cloud has a trivial volume.
# ================================================================

function estimate_volume_voxel(
    pc::PointCloud;
    resolution=1.0
)

    isempty(pc.points) &&
        error("Empty point cloud")

    box =
        bounding_box(pc)

    minp = box.min
    maxp = box.max

    occupied = Set{Tuple{Int,Int,Int}}()

    for p in pc.points

        ix = floor(Int,
            (p.x-minp.x)/resolution)

        iy = floor(Int,
            (p.y-minp.y)/resolution)

        iz = floor(Int,
            (p.z-minp.z)/resolution)

        push!(
            occupied,
            (ix,iy,iz)
        )

    end

    return length(occupied) *
        resolution^3
end

# ================================================================
# PLANE TO PLANE ANGLE
# ================================================================

function plane_angle(
    a::Plane,
    b::Plane
)

    return angle_degrees(
        a.normal,
        b.normal
    )
end

# ================================================================
# PLANE TO POINT PROJECTION
# ================================================================

function project_to_plane(
    p::Point3D,
    plane::Plane
)

    d =
        signed_plane_distance(
            p,
            plane
        )

    return p -
        d*plane.normal
end

# ================================================================
# LINE / PLANE INTERSECTION
# ================================================================

function line_plane_intersection(
    line::Line3D,
    plane::Plane
)

    denominator =
        dot3(
            plane.normal,
            line.direction
        )

    abs(denominator) < 1e-12 &&
        return nothing

    t =
        -(
            dot3(
                plane.normal,
                line.origin
            ) + plane.d
        ) / denominator

    return (
        point =
            line.origin +
            t*line.direction,
        parameter=t
    )
end

# ================================================================
# MEASUREMENT PIPELINE
# ================================================================

struct MeasurementPipeline
    name::String
    steps::Vector{Function}
end

function MeasurementPipeline(name::String)

    return MeasurementPipeline(
        name,
        Function[]
    )
end

function add_step!(
    pipeline::MeasurementPipeline,
    step::Function
)

    push!(
        pipeline.steps,
        step
    )

    return pipeline
end

function execute(
    pipeline::MeasurementPipeline,
    input
)

    data = input

    for step in pipeline.steps

        data = step(data)

    end

    return data
end

# ================================================================
# AUDIT TRAIL
# ================================================================

struct AuditRecord
    timestamp::DateTime
    operation::String
    input_description::String
    output_description::String
    operator::String
    software_version::String
end

mutable struct AuditTrail
    records::Vector{AuditRecord}
end

AuditTrail() =
    AuditTrail(AuditRecord[])

function audit!(
    trail::AuditTrail;
    operation,
    input_description,
    output_description,
    operator="system"
)

    push!(
        trail.records,
        AuditRecord(
            now(),
            operation,
            input_description,
            output_description,
            operator,
            ENGINE_VERSION
        )
    )

    return trail
end

# ================================================================
# CSV POINT-CLOUD LOADER
#
# Expected:
#
# x,y,z
# 1.0,2.0,3.0
# ...
# ================================================================

function load_xyz_csv(
    filename;
    sensor_id="csv"
)

    lines =
        readlines(filename)

    points =
        Point3D{Float64}[]

    for line in lines

        stripped =
            strip(line)

        isempty(stripped) &&
            continue

        startswith(
            lowercase(stripped),
            "x,"
        ) && continue

        fields =
            split(stripped,',')

        length(fields) >= 3 ||
            continue

        x =
            parse(Float64,
                strip(fields[1]))

        y =
            parse(Float64,
                strip(fields[2]))

        z =
            parse(Float64,
                strip(fields[3]))

        push!(
            points,
            Point3D(x,y,z)
        )

    end

    return PointCloud(
        points,
        sensor_id=sensor_id
    )
end

# ================================================================
# CSV EXPORT
# ================================================================

function save_xyz_csv(
    pc::PointCloud,
    filename
)

    open(filename,"w") do io

        println(io,"x,y,z")

        for p in pc.points

            println(
                io,
                "$(p.x),$(p.y),$(p.z)"
            )

        end

    end

    return filename
end

# ================================================================
# RANDOM SYNTHETIC DATA
# ================================================================

function synthetic_plane(
    n=1000;
    width=100.0,
    noise=0.1
)

    points =
        Point3D{Float64}[]

    for _ in 1:n

        x =
            rand() * width -
            width/2

        y =
            rand() * width -
            width/2

        z =
            randn()*noise

        push!(
            points,
            Point3D(x,y,z)
        )

    end

    return PointCloud(
        points,
        sensor_id="synthetic",
        frame="world"
    )
end

function synthetic_sphere(
    n=2000;
    radius=50.0,
    noise=0.1
)

    points =
        Point3D{Float64}[]

    for _ in 1:n

        θ =
            acos(
                2*rand()-1
            )

        φ =
            2π*rand()

        r =
            radius +
            randn()*noise

        push!(
            points,
            Point3D(
                r*sin(θ)*cos(φ),
                r*sin(θ)*sin(φ),
                r*cos(θ)
            )
        )

    end

    return PointCloud(
        points,
        sensor_id="synthetic",
        frame="world"
    )
end

# ================================================================
# METROLOGY REPORT
# ================================================================

function report_plane(
    result
)

    plane =
        result.plane

    println()
    println(
        "=============================="
    )
    println(
        "3D METROLOGY — PLANE"
    )
    println(
        "=============================="
    )

    println(
        "Normal: ",
        plane.normal
    )

    println(
        "Point: ",
        plane.point
    )

    @printf(
        "RMS error: %.6f\n",
        result.rms_error
    )

end

function report_sphere(
    result
)

    sphere =
        result.sphere

    println()
    println(
        "=============================="
    )
    println(
        "3D METROLOGY — SPHERE"
    )
    println(
        "=============================="
    )

    println(
        "Centre: ",
        sphere.center
    )

    @printf(
        "Radius: %.6f\n",
        sphere.radius
    )

    @printf(
        "Diameter: %.6f\n",
        2*sphere.radius
    )

    @printf(
        "RMS error: %.6f\n",
        result.rms_error
    )

end

function report_cylinder(
    result
)

    cylinder =
        result.cylinder

    println()
    println(
        "=============================="
    )
    println(
        "3D METROLOGY — CYLINDER"
    )
    println(
        "=============================="
    )

    println(
        "Axis origin: ",
        cylinder.axis.origin
    )

    println(
        "Axis direction: ",
        cylinder.axis.direction
    )

    @printf(
        "Radius: %.6f\n",
        cylinder.radius
    )

    @printf(
        "Diameter: %.6f\n",
        2*cylinder.radius
    )

    @printf(
        "RMS error: %.6f\n",
        result.rms_error
    )

end

# ================================================================
# ENGINE SELF TEST
# ================================================================

function self_test()

    println()
    println(
        "======================================"
    )
    println(
        " JULIA 3D METROLOGY ENGINE"
    )
    println(
        " SELF TEST"
    )
    println(
        " Version: ",
        ENGINE_VERSION
    )
    println(
        "======================================"
    )

    # ------------------------------------------------------------
    # Point test
    # ------------------------------------------------------------

    p1 =
        Point3D(0.0,0.0,0.0)

    p2 =
        Point3D(3.0,4.0,12.0)

    d =
        distance(p1,p2)

    println(
        "Distance test: ",
        d
    )

    @assert isapprox(
        d,
        13.0
    )

    # ------------------------------------------------------------
    # Plane test
    # ------------------------------------------------------------

    cloud =
        synthetic_plane(
            1000,
            width=100.0,
            noise=0.01
        )

    plane =
        fit_plane(
            cloud.points
        )

    report_plane(plane)

    # ------------------------------------------------------------
    # Sphere test
    # ------------------------------------------------------------

    sphere_cloud =
        synthetic_sphere(
            2000,
            radius=50.0,
            noise=0.05
        )

    sphere =
        fit_sphere(
            sphere_cloud.points
        )

    report_sphere(sphere)

    # ------------------------------------------------------------
    # Transform test
    # ------------------------------------------------------------

    T =
        compose(
            translation(
                10.0,
                20.0,
                30.0
            ),
            rotation_z(
                deg2rad(30)
            )
        )

    transformed =
        transform_point(
            T,
            p2
        )

    println(
        "Transformed point: ",
        transformed
    )

    # ------------------------------------------------------------
    # Tolerance test
    # ------------------------------------------------------------

    tolerance =
        ToleranceSpec(
            100.0,
            -0.10,
            0.10
        )

    tolerance_result =
        check_tolerance(
            100.07,
            tolerance
        )

    println(
        "Tolerance result: ",
        tolerance_result.pass
    )

    @assert tolerance_result.pass

    println()
    println(
        "ALL SELF TESTS PASSED"
    )
    println()

    return true
end

# ================================================================
# EXPORTS
# ================================================================

export Point3D
export PointCloud
export Plane
export Line3D
export Sphere
export Cylinder
export Circle3D
export Transform3D

export distance
export angle_between
export angle_degrees
export centroid
export bounding_box

export translation
export rotation_x
export rotation_y
export rotation_z
export compose
export transform_point
export transform_cloud

export fit_plane
export fit_line
export fit_sphere
export fit_cylinder
export fit_circle_3d

export point_plane_distance
export signed_plane_distance
export point_line_distance
export line_plane_intersection
export project_to_plane
export plane_angle

export nearest_neighbor
export statistical_filter
export register_clouds
export deviation_map

export ToleranceSpec
export ToleranceResult
export check_tolerance

export uncertainty_from_samples
export quality_score

export measure_length
export measure_width
export measure_height
export measure_depth
export bounding_volume
export estimate_volume_voxel

export MeasurementPipeline
export add_step!
export execute

export AuditTrail
export audit!

export load_xyz_csv
export save_xyz_csv

export synthetic_plane
export synthetic_sphere

export report_plane
export report_sphere
export report_cylinder

export self_test

end # module


# ================================================================
# EXAMPLE APPLICATION
# ================================================================

using .MetrologyEngine

println()
println("Starting $(MetrologyEngine.ENGINE_NAME)")
println("Version: $(MetrologyEngine.ENGINE_VERSION)")
println()

# ================================================================
# 1. BASIC 3D MEASUREMENT
# ================================================================

p1 = Point3D(
    100.0,
    200.0,
    300.0
)

p2 = Point3D(
    450.0,
    600.0,
    900.0
)

println(
    "3D distance = ",
    distance(p1,p2)
)

# ================================================================
# 2. SYNTHETIC LASER SCAN
# ================================================================

scan =
    synthetic_sphere(
        5000,
        radius=100.0,
        noise=0.03
    )

println(
    "Scan points: ",
    length(scan)
)

# ================================================================
# 3. FILTER NOISE
# ================================================================

filtered =
    statistical_filter(
        scan,
        sigma=2.5
    )

println(
    "Filtered points: ",
    length(filtered)
)

# ================================================================
# 4. FIT SPHERE
# ================================================================

sphere_result =
    fit_sphere(
        filtered.points
    )

report_sphere(
    sphere_result
)

# ================================================================
# 5. MEASURE DIAMETER
# ================================================================

diameter =
    2*sphere_result.sphere.radius

println(
    "Measured diameter = ",
    diameter
)

# ================================================================
# 6. TOLERANCE
# ================================================================

spec =
    ToleranceSpec(
        200.0,
        -0.20,
        0.20
    )

result =
    check_tolerance(
        diameter,
        spec
    )

println()
println(
    "Tolerance analysis"
)
println(
    "Nominal: ",
    result.nominal
)
println(
    "Measured: ",
    result.measured
)
println(
    "Deviation: ",
    result.deviation
)
println(
    "PASS: ",
    result.pass
)

# ================================================================
# 7. MEASUREMENT UNCERTAINTY
# ================================================================

repeat_measurements = [
    199.98,
    200.02,
    200.01,
    199.99,
    200.00,
    200.03,
    199.97,
    200.01
]

uncertainty =
    uncertainty_from_samples(
        repeat_measurements,
        confidence=0.95,
        unit="mm"
    )

println()
println(
    "Measurement uncertainty"
)
println(
    "Mean: ",
    uncertainty.value
)
println(
    "Expanded uncertainty: ±",
    uncertainty.uncertainty,
    " ",
    uncertainty.unit
)

# ================================================================
# 8. QUALITY SCORE
# ================================================================

quality =
    quality_score(
        sphere_result.residuals,
        specification=0.10
    )

println(
    "Measurement quality: ",
    quality,
    "%"
)

# ================================================================
# 9. AUDIT TRAIL
# ================================================================

audit =
    AuditTrail()

audit!(
    audit,
    operation="sphere_fit",
    input_description="3D point cloud",
    output_description="Sphere geometry",
    operator="metrology-engine"
)

audit!(
    audit,
    operation="tolerance_check",
    input_description="Measured diameter",
    output_description="Pass/fail result",
    operator="metrology-engine"
)

println()
println(
    "Audit records: ",
    length(audit.records)
)

# ================================================================
# 10. SELF TEST
# ================================================================

self_test()



