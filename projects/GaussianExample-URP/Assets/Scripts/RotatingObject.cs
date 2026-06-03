using UnityEngine;

public class RotatingObject : MonoBehaviour
{
    public float rotating_speed = 1f;
    // Update is called once per frame
    void Update()
    {
        this.transform.Rotate(Vector3.up, rotating_speed,Space.Self);
    }
}
